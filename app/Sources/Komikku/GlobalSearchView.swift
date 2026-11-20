// SPDX-License-Identifier: GPL-3.0-or-later
//
// Search a title across every enabled server (or only pinned ones), like
// upstream's Explorer "global search". Servers needing a browser challenge are
// skipped rather than popping up windows.

import AppKit
import SwiftUI

enum ServerSearchState: Equatable {
    case searching
    case done([SearchResult])
    case failed(String)

    var results: [SearchResult] {
        if case .done(let results) = self { return results }
        return []
    }
}

@MainActor
struct GlobalSearchView: View {
    @Environment(AppModel.self) private var model
    var searchFocusRequest: Int

    @State private var term = ""
    @State private var searchedTerm = ""
    @State private var searchPresented = true
    @State private var states: [String: ServerSearchState] = [:]
    @State private var order: [String] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var showEmpty = false

    private static let concurrency = 10

    private var pinnedOnly: Bool {
        (model.settings["explorer-search-global-selected-filters"] as? [String] ?? []).contains("pinned")
    }

    private var targets: [ServerInfo] {
        // Self-hosted servers (Komga, Kavita, Suwayomi…) have no address until configured
        model.servers.filter { $0.trueSearch && $0.baseUrl != nil && (!pinnedOnly || $0.pinned) }
    }

    private var finishedCount: Int {
        states.values.filter { $0 != .searching }.count
    }

    private var withResults: [ServerInfo] {
        order.compactMap { id in
            guard case .done(let results) = states[id], !results.isEmpty else { return nil }
            return model.server(id: id)
        }
    }

    private var searching: [ServerInfo] {
        order.compactMap { states[$0] == .searching ? model.server(id: $0) : nil }
    }

    private struct Outcome: Identifiable {
        let server: ServerInfo
        let state: ServerSearchState
        var id: String { server.id }
    }

    private var emptyOrFailed: [Outcome] {
        order.compactMap { id in
            guard let state = states[id], let server = model.server(id: id) else { return nil }
            switch state {
            case .done(let results) where results.isEmpty: return Outcome(server: server, state: state)
            case .failed: return Outcome(server: server, state: state)
            default: return nil
            }
        }
    }

    var body: some View {
        content
            .navigationTitle("Tüm Kaynaklarda Ara")
            .navigationSubtitle(subtitle)
            .searchable(text: $term, isPresented: $searchPresented, placement: .toolbar, prompt: "Manga adı")
            .onSubmit(of: .search) { start() }
            .onChange(of: searchFocusRequest) { _, _ in searchPresented = true }
            .toolbar {
                ToolbarItemGroup {
                    if searchTask != nil {
                        ProgressView(value: Double(finishedCount), total: Double(max(order.count, 1)))
                            .frame(width: 80)
                        Button {
                            cancel()
                        } label: {
                            Label("Durdur", systemImage: "stop.circle")
                        }
                    }
                    Toggle(isOn: Binding(
                        get: { pinnedOnly },
                        set: { value in
                            Task { @MainActor in
                                await model.setSetting("explorer-search-global-selected-filters", value ? ["pinned"] : [String]())
                            }
                        }
                    )) {
                        Label("Yalnızca sabitlenmiş sunucular", systemImage: "pin")
                    }
                    .help("Yalnızca kenar çubuğuna sabitlenmiş sunucularda ara")
                }
            }
            .onDisappear { cancel() }
    }

    private var subtitle: String {
        if order.isEmpty {
            return "\(targets.count) sunucu"
        }
        let found = withResults.count
        return "\(finishedCount)/\(order.count) sunucu tarandı · \(found) sunucuda sonuç"
    }

    @ViewBuilder
    private var content: some View {
        if order.isEmpty {
            ContentUnavailableView {
                Label("Bir mangayı tüm kaynaklarda arayın", systemImage: "magnifyingglass")
            } description: {
                Text(pinnedOnly
                     ? "Sabitlenmiş \(targets.count) sunucuda aranacak."
                     : "Dil ayarlarınıza uyan \(targets.count) sunucuda aranacak. Tarayıcı doğrulaması isteyen sunucular atlanır.")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(withResults) { server in
                        ServerResultsRow(server: server, results: states[server.id]?.results ?? [])
                    }

                    if !searching.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Aranıyor: " + searching.prefix(6).map(\.name).joined(separator: ", ")
                                 + (searching.count > 6 ? " +\(searching.count - 6)" : ""))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    if !emptyOrFailed.isEmpty {
                        DisclosureGroup(isExpanded: $showEmpty) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(emptyOrFailed) { outcome in
                                    HStack {
                                        Text(outcome.server.name)
                                        Text(flag(for: outcome.server.lang)).font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        switch outcome.state {
                                        case .failed(let message):
                                            Text(message).foregroundStyle(.orange).lineLimit(1)
                                        default:
                                            Text("Sonuç yok").foregroundStyle(.secondary)
                                        }
                                    }
                                    .font(.callout)
                                }
                            }
                            .padding(.top, 6)
                        } label: {
                            Text("Sonuç çıkmayan ya da hata veren \(emptyOrFailed.count) sunucu")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    // MARK: - Searching

    private func cancel() {
        searchTask?.cancel()
        searchTask = nil
    }

    private func start() {
        let query = term.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        cancel()

        let servers = targets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        searchedTerm = query
        order = servers.map(\.id)
        states = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, ServerSearchState.searching) })
        let backend = model.backend

        searchTask = Task { @MainActor in
            await withTaskGroup(of: (String, ServerSearchState).self) { group in
                var next = 0
                while next < min(Self.concurrency, servers.count) {
                    let server = servers[next]
                    next += 1
                    group.addTask {
                        await GlobalSearchView.search(server: server, term: query, backend: backend)
                    }
                }

                for await (id, state) in group {
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }
                    states[id] = state
                    if next < servers.count {
                        let server = servers[next]
                        next += 1
                        group.addTask {
                            await GlobalSearchView.search(server: server, term: query, backend: backend)
                        }
                    }
                }
            }
            if !Task.isCancelled {
                searchTask = nil
            }
            AppLog.write("global search '\(query)': \(withResults.count)/\(servers.count) servers with results")
        }
    }

    nonisolated private static func search(server: ServerInfo, term: String, backend: Backend) async -> (String, ServerSearchState) {
        do {
            let results: [SearchResult] = try await backend.call(
                "explorer.search", ["server_id": server.id, "term": term, "interactive": false]
            )
            return (server.id, .done(results))
        } catch {
            return (server.id, .failed(error.localizedDescription))
        }
    }
}

@MainActor
struct ServerResultsRow: View {
    let server: ServerInfo
    let results: [SearchResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(server.name).font(.headline)
                Text(flag(for: server.lang))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(results.count) sonuç")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                NavigationLink(value: Route.server(server.id)) {
                    Text("Sunucuyu Aç")
                }
                .buttonStyle(.link)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(results) { result in
                        NavigationLink(value: Route.searchResult(serverID: server.id, result: result)) {
                            VStack(alignment: .leading, spacing: 4) {
                                CoverImage(remoteURL: result.cover, serverID: server.id)
                                    .frame(width: 110)
                                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                                Text(result.name)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(2)
                                    .frame(width: 110, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 6)
            }
        }
    }
}
