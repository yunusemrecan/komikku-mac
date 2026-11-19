// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

enum Route: Hashable {
    case manga(Int)
    case searchResult(serverID: String, result: SearchResult)
    case server(String)
}

@MainActor
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .library
    @State private var path = NavigationPath()
    @State private var searchFocusRequest = 0

    var body: some View {
        Group {
            switch model.state {
            case .starting:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Başlatılıyor…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Arka uç başlatılamadı", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message).textSelection(.enabled)
                } actions: {
                    Button("Günlüğü Göster") {
                        NSWorkspace.shared.activateFileViewerSelecting([Backend.logURL])
                    }
                }
            case .ready:
                splitView
            }
        }
        .alert("Hata", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .focusedSceneValue(\.navigationActions, NavigationActions(
            showLibrary: { select(.library) },
            showServers: { select(.allServers) },
            focusSearch: { searchFocusRequest += 1 }
        ))
    }

    private func select(_ item: SidebarItem) {
        selection = item
        path = NavigationPath()
    }

    private var splitView: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            NavigationStack(path: $path) {
                rootView
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case .manga(let id):
                            MangaDetailView(source: .library(id))
                        case .searchResult(let serverID, let result):
                            MangaDetailView(source: .search(serverID: serverID, result: result))
                        case .server(let id):
                            ServerBrowseView(serverID: id, searchFocusRequest: searchFocusRequest)
                        }
                    }
            }
        }
        .onChange(of: selection) { _, _ in
            path = NavigationPath()
        }
    }

    @ViewBuilder
    private var rootView: some View {
        switch selection {
        case .library, .none:
            LibraryView(searchFocusRequest: searchFocusRequest)
        case .allServers:
            ServersView(searchFocusRequest: searchFocusRequest)
        case .server(let id):
            ServerBrowseView(serverID: id, searchFocusRequest: searchFocusRequest)
                .id(id)
        }
    }
}

@MainActor
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Kütüphane", systemImage: "books.vertical")
                    .badge(model.library.reduce(0) { $0 + $1.nbUnreadChapters })
                    .tag(SidebarItem.library)
                Label("Tüm Sunucular", systemImage: "globe")
                    .tag(SidebarItem.allServers)
            }

            if !model.pinnedServers.isEmpty {
                Section("Sabitlenmiş") {
                    ForEach(model.pinnedServers) { server in
                        Label {
                            Text(server.name)
                        } icon: {
                            Text(flag(for: server.lang))
                        }
                        .tag(SidebarItem.server(server.id))
                        .contextMenu {
                            Button("Sabitlemeyi Kaldır") {
                                Task { await model.setPinned(server, false) }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if let status = model.updateStatus {
                HStack(spacing: 6) {
                    if model.isUpdatingLibrary {
                        ProgressView().controlSize(.mini)
                    }
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(8)
            }
        }
    }
}

/// Language code -> short label shown next to server names.
func flag(for lang: String) -> String {
    lang.isEmpty ? "🌐" : lang.uppercased().replacingOccurrences(of: "_", with: "-")
}
