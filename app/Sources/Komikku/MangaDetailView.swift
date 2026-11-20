// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

@MainActor
struct MangaDetailView: View {
    enum Source: Hashable {
        case library(Int)
        case search(serverID: String, result: SearchResult)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.openReader) private var openReaderAction
    let source: Source

    @State private var manga: Manga?
    @State private var loading = false
    @State private var error: String?
    @State private var selection = Set<Int>()
    @State private var newestFirst = true
    @State private var refreshing = false

    var body: some View {
        Group {
            if let manga {
                detail(manga)
            } else if let error {
                ContentUnavailableView {
                    Label("Manga açılamadı", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Yeniden Dene") { Task { @MainActor in await load() } }
                }
            } else {
                ProgressView("Yükleniyor…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(manga?.name ?? title)
        .navigationSubtitle(manga?.serverName ?? "")
        .toolbar { toolbar }
        .task { await load() }
        .onChange(of: model.mangaRevision[manga?.id ?? -1]) { _, _ in
            Task { @MainActor in await reload() }
        }
    }

    private var title: String {
        switch source {
        case .library: return ""
        case .search(_, let result): return result.name
        }
    }

    // MARK: - Loading

    @MainActor
    private func load() async {
        error = nil
        do {
            switch source {
            case .library(let id):
                manga = try await model.backend.call("manga.get", ["manga_id": id])
            case .search(let serverID, let result):
                var params: [String: Any] = ["server_id": serverID, "slug": result.slug, "name": result.name]
                if let url = result.url { params["url"] = url }
                if let cover = result.cover { params["cover"] = cover }
                manga = try await model.backend.call("manga.open", params)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func reload() async {
        guard let id = manga?.id else { return }
        if let fresh: Manga = try? await model.backend.call("manga.get", ["manga_id": id]) {
            manga = fresh
        }
    }

    @MainActor
    private func refresh() async {
        guard let id = manga?.id else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let result: MangaRefresh = try await model.backend.call("manga.refresh", ["manga_id": id])
            manga = result.manga
            await model.reloadLibrary()
        } catch {
            model.report(error)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if let manga {
                Button {
                    revealInFinder(manga)
                } label: {
                    Label("Finder'da Göster", systemImage: "folder")
                }
                .help("İndirilen bölümlerin klasörünü Finder'da göster")

                Button {
                    Task { @MainActor in await refresh() }
                } label: {
                    Label("Bölümleri Güncelle", systemImage: "arrow.clockwise")
                }
                .disabled(refreshing)
                .help("Sunucudan yeni bölümleri al")

                if manga.inLibrary {
                    Button {
                        Task { @MainActor in await model.removeFromLibrary(manga) }
                        self.manga?.inLibrary = false
                    } label: {
                        Label("Kütüphaneden Kaldır", systemImage: "books.vertical.fill")
                    }
                    .help("Kütüphaneden kaldır")
                } else {
                    Button {
                        Task { @MainActor in
                            if let updated = await model.addToLibrary(manga) {
                                self.manga?.inLibrary = updated.inLibrary
                            }
                        }
                    } label: {
                        Label("Kütüphaneye Ekle", systemImage: "books.vertical")
                    }
                    .help("Kütüphaneye ekle")
                }
            }
        }
    }

    // MARK: - Layout

    private func detail(_ manga: Manga) -> some View {
        let ordered = manga.chaptersInReadingOrder
        let chapters: [Chapter] = newestFirst ? Array(ordered.reversed()) : ordered

        return List(selection: $selection) {
            Section {
                header(manga)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            }

            Section {
                ForEach(chapters) { chapter in
                    ChapterRow(chapter: chapter, progress: model.downloadProgress[chapter.id])
                        .tag(chapter.id)
                }
            } header: {
                HStack {
                    Text("\(manga.chapters?.count ?? 0) bölüm")
                    Spacer()
                    Button {
                        newestFirst.toggle()
                    } label: {
                        Label(newestFirst ? "En yeni önce" : "En eski önce",
                              systemImage: newestFirst ? "arrow.down" : "arrow.up")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            chapterMenu(ids: Array(ids), manga: manga)
        } primaryAction: { ids in
            if let id = ids.first {
                openReader(manga: manga, chapterID: id)
            }
        }
        .onKeyPress(.return) {
            guard let id = selection.first else { return .ignored }
            openReader(manga: manga, chapterID: id)
            return .handled
        }
    }

    private func header(_ manga: Manga) -> some View {
        HStack(alignment: .top, spacing: 20) {
            CoverImage(localPath: manga.coverPath)
                .frame(width: 170)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 10) {
                Text(manga.name)
                    .font(.title.bold())
                    .textSelection(.enabled)

                if let authors = manga.authors, !authors.isEmpty {
                    Text(authors.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    if let status = manga.status {
                        Tag(text: statusLabel(status))
                    }
                    if let server = manga.serverName {
                        Tag(text: server)
                    }
                    if manga.nbUnreadChapters > 0 {
                        Tag(text: "\(manga.nbUnreadChapters) okunmamış")
                    }
                }

                if let genres = manga.genres, !genres.isEmpty {
                    Text(genres.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let resume = manga.resumeChapter {
                    Button {
                        openReader(manga: manga, chapterID: resume.id)
                    } label: {
                        Label(resume.lastPageReadIndex != nil || manga.chapters?.contains(where: \.read) == true
                              ? "Okumaya Devam Et: \(resume.title)"
                              : "Okumaya Başla",
                              systemImage: "book")
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut("o", modifiers: .command)
                }

                if let synopsis = manga.plainSynopsis, !synopsis.isEmpty {
                    Text(synopsis)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "complete": return "Tamamlandı"
        case "ongoing": return "Devam ediyor"
        case "suspended": return "Askıda"
        case "hiatus": return "Ara verildi"
        default: return status
        }
    }

    @ViewBuilder
    private func chapterMenu(ids: [Int], manga: Manga) -> some View {
        if ids.count == 1, let id = ids.first {
            Button("Oku") { openReader(manga: manga, chapterID: id) }
            Divider()
        }
        if !ids.isEmpty {
            Button("Okundu Olarak İşaretle") {
                Task { @MainActor in await model.setRead(ids, read: true, mangaID: manga.id) }
            }
            Button("Okunmadı Olarak İşaretle") {
                Task { @MainActor in await model.setRead(ids, read: false, mangaID: manga.id) }
            }
            if ids.count == 1, let id = ids.first, let chapters = manga.chapters {
                let older = chapters.filter { c in
                    c.rank < (chapters.first { $0.id == id }?.rank ?? 0) && !c.read
                }.map(\.id)
                Button("Öncekilerin Hepsini Okundu İşaretle") {
                    Task { @MainActor in await model.setRead(older + [id], read: true, mangaID: manga.id) }
                }
                .disabled(older.isEmpty)
            }
            Divider()
            Button("İndir") {
                Task { @MainActor in await model.download(ids, mangaID: manga.id) }
            }
            Button("İndirilenleri Sil") {
                Task { @MainActor in await model.clearDownloads(ids, mangaID: manga.id) }
            }
        }
    }

    private func revealInFinder(_ manga: Manga) {
        guard let path = manga.path else { return }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // Nothing downloaded yet: show the nearest existing parent folder
            var parent = url.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: parent.path) && parent.path != "/" {
                parent = parent.deletingLastPathComponent()
            }
            NSWorkspace.shared.open(parent)
        }
    }

    private func openReader(manga: Manga, chapterID: Int) {
        openReaderAction(ReaderTarget(mangaId: manga.id, chapterId: chapterID))
    }
}

@MainActor
struct ChapterRow: View {
    let chapter: Chapter
    let progress: Double?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(chapter.title)
                    .foregroundStyle(chapter.read ? .secondary : .primary)
                    .fontWeight(chapter.recent ? .semibold : .regular)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let date = chapter.date {
                        Text(formatDate(date))
                    }
                    if let last = chapter.lastPageReadIndex, !chapter.read {
                        Text("· Sayfa \(last + 1)\(chapter.nbPages.map { "/\($0)" } ?? "")")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let progress {
                ProgressView(value: progress).frame(width: 60)
            } else if chapter.downloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.secondary)
                    .help("İndirildi")
            }
            if chapter.recent && !chapter.read {
                Circle().fill(.tint).frame(width: 7, height: 7)
            }
        }
        .padding(.vertical, 2)
    }

    private func formatDate(_ iso: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: String(iso.prefix(10))) else { return iso }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

@MainActor
struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}
