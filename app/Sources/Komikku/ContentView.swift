// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

enum Route: Hashable {
    case manga(Int)
    case reader(ReaderTarget)
    case searchResult(serverID: String, result: SearchResult)
    case server(String)
}

@MainActor
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var selection: SidebarItem? = .library
    @State private var path: [Route] = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @AppStorage(ReaderPreferences.separateWindowKey) private var readerInSeparateWindow = false
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
        .task(id: model.state) {
            if model.state == .ready { await runAutotestIfRequested() }
        }
        .focusedSceneValue(\.navigationActions, NavigationActions(
            showLibrary: { select(.library) },
            showServers: { select(.allServers) },
            showGlobalSearch: {
                select(.globalSearch)
                searchFocusRequest += 1
            },
            focusSearch: { searchFocusRequest += 1 }
        ))
    }

    /// CI hook: KOMIKKU_AUTOTEST="server_id:search term" opens the first chapter of the first result.
    private func runAutotestIfRequested() async {
        guard let spec = ProcessInfo.processInfo.environment["KOMIKKU_AUTOTEST"] else { return }
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        AppLog.write("autotest: \(spec)")
        do {
            let results: [SearchResult] = try await model.backend.call("explorer.search", ["server_id": parts[0], "term": parts[1]])
            guard let first = results.first else { AppLog.write("autotest: no results"); return }
            let manga: Manga = try await model.backend.call("manga.open", ["server_id": parts[0], "slug": first.slug, "name": first.name])
            guard let chapter = manga.chaptersInReadingOrder.first else { AppLog.write("autotest: no chapters"); return }
            AppLog.write("autotest: opening \(manga.name) / \(chapter.title)")
            openReader(ReaderTarget(mangaId: manga.id, chapterId: chapter.id))
        } catch {
            AppLog.write("autotest: failed: \(error)")
        }
    }

    private var isReading: Bool {
        if case .reader = path.last { return true }
        return false
    }

    private func openReader(_ target: ReaderTarget) {
        if readerInSeparateWindow {
            openWindow(id: "reader", value: target)
        } else if case .reader = path.last {
            path[path.count - 1] = .reader(target)
        } else {
            path.append(.reader(target))
        }
    }

    private func select(_ item: SidebarItem) {
        selection = item
        path = []
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
                        case .reader(let target):
                            ReaderView(target: target, embedded: true)
                        }
                    }
            }
        }
        .environment(\.openReader, OpenReaderAction { target in openReader(target) })
        .onChange(of: selection) { _, _ in
            path = []
        }
        .onChange(of: isReading) { _, reading in
            // Give the page the whole window while reading; bring the sidebar back after
            withAnimation { columnVisibility = reading ? .detailOnly : .all }
        }
    }

    @ViewBuilder
    private var rootView: some View {
        switch selection {
        case .library, .none:
            LibraryView(searchFocusRequest: searchFocusRequest)
        case .globalSearch:
            GlobalSearchView(searchFocusRequest: searchFocusRequest)
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
                Label("Tüm Kaynaklarda Ara", systemImage: "magnifyingglass")
                    .tag(SidebarItem.globalSearch)
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
