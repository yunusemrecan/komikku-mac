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
        .environment(\.openRoute, OpenRouteAction { route in path.append(route) })
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
            LibraryView(category: nil, searchFocusRequest: searchFocusRequest)
        case .category(let id):
            LibraryView(category: id, searchFocusRequest: searchFocusRequest)
        case .history:
            HistoryView(searchFocusRequest: searchFocusRequest)
        case .downloads:
            DownloadsView()
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

    @State private var newCategoryName = ""
    @State private var showNewCategory = false
    @State private var renaming: MangaCategory?
    @State private var renameText = ""
    @State private var deleting: MangaCategory?

    var body: some View {
        List(selection: $selection) {
            Section("Kütüphane") {
                Label("Tümü", systemImage: "books.vertical")
                    .badge(model.library.reduce(0) { $0 + $1.nbUnreadChapters })
                    .tag(SidebarItem.library)
                ForEach(model.categories) { category in
                    Label(category.label, systemImage: "tag")
                        .badge(category.count ?? 0)
                        .tag(SidebarItem.category(category.id))
                        .contextMenu {
                            Button("Yeniden Adlandır…") {
                                renameText = category.label
                                renaming = category
                            }
                            Button("Sil…", role: .destructive) { deleting = category }
                        }
                }
                if !model.categories.isEmpty {
                    Label("Kategorisiz", systemImage: "tag.slash")
                        .tag(SidebarItem.category(-1))
                }
                Label("Geçmiş", systemImage: "clock")
                    .tag(SidebarItem.history)
                Label("İndirmeler", systemImage: "arrow.down.circle")
                    .badge(model.downloads.count)
                    .tag(SidebarItem.downloads)
            }

            Section("Keşfet") {
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
        .contextMenu {
            Button("Yeni Kategori…") { showNewCategory = true }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                if let toast = model.toast {
                    Text(toast)
                        .font(.caption)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .transition(.opacity)
                }
                HStack(spacing: 6) {
                    Button {
                        newCategoryName = ""
                        showNewCategory = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Yeni kategori")
                    if model.isUpdatingLibrary {
                        ProgressView().controlSize(.mini)
                    }
                    if let status = model.updateStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
            }
            .padding(8)
            .animation(.default, value: model.toast)
        }
        .alert("Yeni Kategori", isPresented: $showNewCategory) {
            TextField("Ad", text: $newCategoryName)
            Button("Ekle") {
                let name = newCategoryName
                Task { @MainActor in await model.createCategory(name) }
            }
            Button("Vazgeç", role: .cancel) {}
        }
        .alert("Kategoriyi Yeniden Adlandır", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Ad", text: $renameText)
            Button("Kaydet") {
                if let category = renaming {
                    let name = renameText
                    Task { @MainActor in await model.renameCategory(category.id, name) }
                }
            }
            Button("Vazgeç", role: .cancel) {}
        }
        .confirmationDialog("“\(deleting?.label ?? "")” kategorisi silinsin mi?", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )) {
            Button("Sil", role: .destructive) {
                if let category = deleting {
                    if selection == .category(category.id) { selection = .library }
                    Task { @MainActor in await model.deleteCategory(category.id) }
                }
            }
        } message: {
            Text("Mangalar kütüphanede kalır, yalnızca kategori silinir.")
        }
    }
}

/// Language code -> short label shown next to server names.
func flag(for lang: String) -> String {
    lang.isEmpty ? "🌐" : lang.uppercased().replacingOccurrences(of: "_", with: "-")
}
