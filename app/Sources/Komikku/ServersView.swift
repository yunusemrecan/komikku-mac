// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

@MainActor
struct ServersView: View {
    @Environment(AppModel.self) private var model
    var searchFocusRequest: Int

    @State private var filter = ""
    @State private var searchPresented = false

    private var grouped: [(lang: String, servers: [ServerInfo])] {
        let filtered = model.servers.filter {
            filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)
        }
        let groups = Dictionary(grouping: filtered, by: \.lang)
        return groups.keys.sorted { languageName($0) < languageName($1) }.map { lang in
            (lang, groups[lang]!.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
    }

    private func languageName(_ code: String) -> String {
        code.isEmpty ? "Çok dilli" : (model.languages[code] ?? code)
    }

    var body: some View {
        List {
            ForEach(grouped, id: \.lang) { group in
                Section(languageName(group.lang)) {
                    ForEach(group.servers) { server in
                        NavigationLink(value: Route.server(server.id)) {
                            ServerRow(server: server)
                        }
                        .contextMenu {
                            Button(server.pinned ? "Sabitlemeyi Kaldır" : "Kenar Çubuğuna Sabitle") {
                                Task { await model.setPinned(server, !server.pinned) }
                            }
                            if let base = server.baseUrl, let url = URL(string: base) {
                                Button("Web Sitesini Aç") { NSWorkspace.shared.open(url) }
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if grouped.isEmpty {
                ContentUnavailableView.search(text: filter)
            }
        }
        .navigationTitle("Sunucular")
        .navigationSubtitle("\(model.servers.count) sunucu")
        .searchable(text: $filter, isPresented: $searchPresented, placement: .toolbar, prompt: "Sunucu ara")
        .onChange(of: searchFocusRequest) { _, _ in searchPresented = true }
        .toolbar {
            SettingsLink {
                Label("Diller", systemImage: "character.bubble")
            }
            .help("Gösterilecek sunucu dillerini seç")
        }
    }
}

@MainActor
struct ServerRow: View {
    @Environment(AppModel.self) private var model
    let server: ServerInfo

    var body: some View {
        HStack(spacing: 10) {
            CoverImage(localPath: server.logoPath, remoteURL: server.logoUrl, serverID: server.id)
                .frame(width: 22, height: 22)
                .aspectRatio(1, contentMode: .fit)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                if let description = server.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if server.isNsfw {
                Text("18+")
                    .font(.caption2.bold())
                    .padding(.horizontal, 4)
                    .background(.red.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
            }
            if server.pinned {
                Image(systemName: "pin.fill").foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
struct ServerBrowseView: View {
    @Environment(AppModel.self) private var model
    let serverID: String
    var searchFocusRequest: Int

    enum Mode: String, CaseIterable, Identifiable {
        case popular, latest, search
        var id: String { rawValue }
        var label: String {
            switch self {
            case .popular: return "Popüler"
            case .latest: return "Son Güncellenenler"
            case .search: return "Arama"
            }
        }
    }

    @State private var mode: Mode = .popular
    @State private var term = ""
    @State private var searchPresented = false
    @State private var results: [SearchResult] = []
    @State private var loading = false
    @State private var error: String?
    @State private var loadToken = 0
    @State private var filterDefs: [ServerFilter] = []
    @State private var filterValues: [String: JSONValue] = [:]
    @State private var filterDefaults: [String: JSONValue] = [:]
    @State private var showFilters = false

    private var filtersChanged: Bool { !filterDefs.isEmpty && filterValues != filterDefaults }

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 18)]

    private var server: ServerInfo? { model.server(id: serverID) }

    private var availableModes: [Mode] {
        guard let server else { return [.search] }
        var modes: [Mode] = []
        if server.hasPopular { modes.append(.popular) }
        if server.hasLatest { modes.append(.latest) }
        if server.trueSearch || modes.isEmpty { modes.append(.search) }
        return modes
    }

    var body: some View {
        content
            .navigationTitle(server?.name ?? serverID)
            .navigationSubtitle(server.map { model.languages[$0.lang] ?? $0.lang } ?? "")
            .searchable(text: $term, isPresented: $searchPresented, placement: .toolbar, prompt: "\(server?.name ?? "") içinde ara")
            .onSubmit(of: .search) {
                mode = .search
                reload()
            }
            .onChange(of: searchFocusRequest) { _, _ in searchPresented = true }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Görünüm", selection: $mode) {
                        ForEach(availableModes) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                ToolbarItem {
                    if !filterDefs.isEmpty {
                        Button {
                            showFilters.toggle()
                        } label: {
                            Label("Filtreler", systemImage: filtersChanged
                                  ? "line.3.horizontal.decrease.circle.fill"
                                  : "line.3.horizontal.decrease.circle")
                        }
                        .help("Arama filtreleri")
                        .popover(isPresented: $showFilters, arrowEdge: .bottom) {
                            ServerFiltersPopover(filters: filterDefs, values: $filterValues, defaults: filterDefaults) {
                                showFilters = false
                                reload()
                            }
                        }
                    }
                }
                ToolbarItem {
                    if let server {
                        Button {
                            Task { await model.setPinned(server, !server.pinned) }
                        } label: {
                            Label(server.pinned ? "Sabitlemeyi Kaldır" : "Sabitle",
                                  systemImage: server.pinned ? "pin.slash" : "pin")
                        }
                    }
                }
            }
            .onChange(of: mode) { _, _ in reload() }
            .task {
                if !availableModes.contains(mode) {
                    mode = availableModes.first ?? .search
                }
                if server?.hasFilters == true,
                   let info: ServerFiltersInfo = try? await model.backend.call("server.filters", ["server_id": serverID]) {
                    filterDefs = info.filters
                    filterDefaults = info.values
                    filterValues = info.values
                }
                reload()
            }
    }

    @ViewBuilder
    private var content: some View {
        if loading && results.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            ContentUnavailableView {
                Label("Yüklenemedi", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Yeniden Dene") { reload() }
            }
        } else if results.isEmpty {
            if mode == .search && term.isEmpty {
                ContentUnavailableView("Aramak için yazın", systemImage: "magnifyingglass",
                                       description: Text("⌘F ile arama alanına geçebilirsiniz."))
            } else {
                ContentUnavailableView("Sonuç yok", systemImage: "tray")
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(results) { result in
                        NavigationLink(value: Route.searchResult(serverID: serverID, result: result)) {
                            VStack(alignment: .leading, spacing: 6) {
                                CoverImage(remoteURL: result.cover, serverID: serverID)
                                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                                Text(result.name)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(2)
                                if let last = result.lastChapter {
                                    Text("Bölüm \(last)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .overlay(alignment: .top) {
                if loading { ProgressView().controlSize(.small).padding(6) }
            }
        }
    }

    private func reload() {
        loadToken += 1
        let token = loadToken
        let currentMode = mode
        let currentTerm = term
        error = nil
        if currentMode == .search && currentTerm.trimmingCharacters(in: .whitespaces).isEmpty {
            results = []
            loading = false
            return
        }
        loading = true
        Task {
            do {
                let method: String
                var params: [String: Any] = ["server_id": serverID]
                if !filterValues.isEmpty {
                    params["filters"] = filterValues.mapValues(\.any)
                }
                switch currentMode {
                case .popular: method = "explorer.popular"
                case .latest: method = "explorer.latest"
                case .search:
                    method = "explorer.search"
                    params["term"] = currentTerm
                }
                let items: [SearchResult] = try await model.backend.call(method, params)
                guard token == loadToken else { return }
                results = items
            } catch {
                guard token == loadToken else { return }
                results = []
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}
