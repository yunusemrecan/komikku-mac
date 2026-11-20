// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

@MainActor
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openReader) private var openReader
    var searchFocusRequest: Int

    @State private var filter = ""
    @State private var searchPresented = false
    @State private var onlyUnread = false

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 18)]

    private var mangas: [Manga] {
        model.library.filter { manga in
            (filter.isEmpty || manga.name.localizedCaseInsensitiveContains(filter)) &&
            (!onlyUnread || manga.nbUnreadChapters > 0)
        }
    }

    var body: some View {
        Group {
            if model.library.isEmpty {
                ContentUnavailableView {
                    Label("Kütüphane boş", systemImage: "books.vertical")
                } description: {
                    Text("Bir sunucudan manga bulup kütüphaneye ekleyin.")
                } actions: {
                    NavigationLink("Sunuculara Göz At", value: Route.server(model.pinnedServers.first?.id ?? "mangadex"))
                }
            } else if mangas.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(mangas) { manga in
                            NavigationLink(value: Route.manga(manga.id)) {
                                LibraryItem(manga: manga)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { contextMenu(for: manga) }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("Kütüphane")
        .navigationSubtitle("\(model.library.count) manga")
        .searchable(text: $filter, isPresented: $searchPresented, placement: .toolbar, prompt: "Kütüphanede ara")
        .onChange(of: searchFocusRequest) { _, _ in searchPresented = true }
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $onlyUnread) {
                    Label("Yalnızca okunmamışlar", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Yalnızca okunmamış bölümü olanları göster")

                Button {
                    Task { await model.updateLibrary() }
                } label: {
                    Label("Güncelle", systemImage: "arrow.clockwise")
                }
                .help("Yeni bölümleri denetle (⌘R)")
                .disabled(model.isUpdatingLibrary)
            }
        }
        .task {
            await model.reloadLibrary()
        }
    }

    @ViewBuilder
    private func contextMenu(for manga: Manga) -> some View {
        Button("Okumaya Devam Et") {
            Task {
                if let full: Manga = try? await model.backend.call("manga.get", ["manga_id": manga.id]),
                   let chapter = full.resumeChapter {
                    openReader(ReaderTarget(mangaId: manga.id, chapterId: chapter.id))
                }
            }
        }
        Divider()
        Button("Kütüphaneden Kaldır", role: .destructive) {
            Task { await model.removeFromLibrary(manga) }
        }
    }
}

@MainActor
struct LibraryItem: View {
    let manga: Manga

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverImage(localPath: manga.coverPath)
                .overlay(alignment: .topTrailing) {
                    if manga.nbUnreadChapters > 0 {
                        Text("\(manga.nbUnreadChapters)")
                            .font(.caption.bold().monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint, in: Capsule())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            Text(manga.name)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            if let server = manga.serverName {
                Text(server)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}
