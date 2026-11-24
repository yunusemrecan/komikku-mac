// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

@MainActor
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openReader) private var openReader
    @Environment(\.openRoute) private var openRoute
    /// nil = all, -1 = uncategorized, otherwise a category id
    var category: Int?
    var searchFocusRequest: Int

    @State private var search = ""
    @State private var searchPresented = false
    @State private var selection = Set<Int>()
    @State private var anchor: Int?
    @State private var confirmRemove = false

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 18)]

    private var mangas: [Manga] {
        model.libraryMangas(category: category, search: search)
    }

    private var title: String {
        guard let category else { return String(localized: "Kütüphane") }
        if category == -1 { return String(localized: "Kategorisiz") }
        return model.categories.first { $0.id == category }?.label ?? String(localized: "Kategori")
    }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationSubtitle(selection.isEmpty ? "\(mangas.count) manga" : String(localized: "\(selection.count) seçili"))
            .searchable(text: $search, isPresented: $searchPresented, placement: .toolbar, prompt: String(localized: "Ad, sunucu ya da tür"))
            .onChange(of: searchFocusRequest) { _, _ in searchPresented = true }
            .toolbar { toolbar }
            .task { await model.reloadLibrary() }
            .onChange(of: category) { _, _ in selection = [] }
            .confirmationDialog("\(selection.count) manga kütüphaneden kaldırılsın mı?",
                                isPresented: $confirmRemove) {
                Button("Kaldır", role: .destructive) {
                    let ids = Array(selection)
                    selection = []
                    Task { @MainActor in await model.removeFromLibrary(ids) }
                }
            } message: {
                Text("İndirilen bölümler de silinir.")
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.library.isEmpty {
            ContentUnavailableView {
                Label("Kütüphane boş", systemImage: "books.vertical")
            } description: {
                Text("Bir sunucudan manga bulup kütüphaneye ekleyin.")
            }
        } else if mangas.isEmpty {
            if search.isEmpty {
                ContentUnavailableView("Bu görünümde manga yok", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("Filtreleri ya da kategoriyi değiştirin."))
            } else {
                ContentUnavailableView.search(text: search)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(mangas) { manga in
                        LibraryItem(manga: manga, selected: selection.contains(manga.id))
                            .onTapGesture(count: 2) {
                                selection = [manga.id]
                                openRoute(.manga(manga.id))
                            }
                            .simultaneousGesture(TapGesture().onEnded {
                                click(manga)
                            })
                            .contextMenu { contextMenu(for: manga) }
                    }
                }
                .padding(20)
            }
            .background {
                // Clicking empty space clears the selection
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { selection = [] }
            }
            .onKeyPress(.escape) {
                guard !selection.isEmpty else { return .ignored }
                selection = []
                return .handled
            }
            .onKeyPress(.return) {
                guard selection.count == 1, let id = selection.first else { return .ignored }
                openRoute(.manga(id))
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: "a"), phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                selection = Set(mangas.map(\.id))
                return .handled
            }
            .focusable()
            .focusEffectDisabled()
        }
    }

    /// Finder-like selection: click selects, ⌘-click toggles, ⇧-click extends.
    private func click(_ manga: Manga) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(manga.id) { selection.remove(manga.id) } else { selection.insert(manga.id) }
            anchor = manga.id
        } else if flags.contains(.shift), let anchor,
                  let a = mangas.firstIndex(where: { $0.id == anchor }),
                  let b = mangas.firstIndex(where: { $0.id == manga.id }) {
            selection = Set(mangas[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [manga.id]
            anchor = manga.id
        }
    }

    /// The mangas a context-menu action applies to.
    private func targets(for manga: Manga) -> [Int] {
        selection.contains(manga.id) ? Array(selection) : [manga.id]
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if !selection.isEmpty {
                selectionActions(Array(selection))
            }

            Menu {
                Picker("Sıralama", selection: Binding(
                    get: { model.librarySortOrder },
                    set: { order in Task { @MainActor in await model.setSetting("library-sort-order", order.rawValue) } }
                )) {
                    ForEach(LibrarySortOrder.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                filterToggle("unread", String(localized: "Okunmamış bölümü olanlar"))
                filterToggle("recents", String(localized: "Yeni bölümü olanlar"))
                filterToggle("downloaded", String(localized: "İndirilmiş bölümü olanlar"))
            } label: {
                Label("Sırala ve Filtrele", systemImage: model.libraryFilters.isEmpty
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
            }
            .help("Sırala ve filtrele")

            Button {
                Task { @MainActor in await model.updateLibrary() }
            } label: {
                Label("Güncelle", systemImage: "arrow.clockwise")
            }
            .help("Yeni bölümleri denetle (⌘R)")
            .disabled(model.isUpdatingLibrary)
        }
    }

    private func filterToggle(_ key: String, _ label: String) -> some View {
        Toggle(label, isOn: Binding(
            get: { model.libraryFilters.contains(key) },
            set: { _ in Task { @MainActor in await model.toggleLibraryFilter(key) } }
        ))
    }

    @ViewBuilder
    private func selectionActions(_ ids: [Int]) -> some View {
        Button {
            Task { @MainActor in await model.updateLibrary(mangaIDs: ids) }
        } label: {
            Label("Seçilenleri Güncelle", systemImage: "arrow.triangle.2.circlepath")
        }
        .help("Seçilenlerde yeni bölümleri denetle")

        categoriesMenu(ids)

        Menu {
            Button("Tümünü Okundu İşaretle") {
                Task { @MainActor in await model.setAllRead(ids, read: true) }
            }
            Button("Tümünü Okunmadı İşaretle") {
                Task { @MainActor in await model.setAllRead(ids, read: false) }
            }
            Divider()
            Button("Kütüphaneden Kaldır…", role: .destructive) {
                confirmRemove = true
            }
        } label: {
            Label("Diğer", systemImage: "ellipsis.circle")
        }
    }

    private func categoriesMenu(_ ids: [Int]) -> some View {
        Menu {
            if model.categories.isEmpty {
                Text("Henüz kategori yok — kenar çubuğundan ekleyin")
            }
            ForEach(model.categories) { category in
                let members = ids.filter { id in
                    model.library.first { $0.id == id }?.categories?.contains(category.id) == true
                }
                Toggle(category.label, isOn: Binding(
                    get: { !members.isEmpty && members.count == ids.count },
                    set: { on in Task { @MainActor in await model.assign(ids, to: category.id, on) } }
                ))
            }
        } label: {
            Label("Kategoriler", systemImage: "tag")
        }
        .help("Kategorilere ekle/çıkar")
    }

    @ViewBuilder
    private func contextMenu(for manga: Manga) -> some View {
        let ids = targets(for: manga)
        if ids.count == 1 {
            Button("Aç") { openRoute(.manga(manga.id)) }
            Button("Kısayol Bağlantısını Kopyala") { URLAction.copyLink(forManga: manga.id) }
            Button("Okumaya Devam Et") {
                Task { @MainActor in
                    if let full: Manga = try? await model.backend.call("manga.get", ["manga_id": manga.id]),
                       let chapter = full.resumeChapter {
                        openReader(ReaderTarget(mangaId: manga.id, chapterId: chapter.id))
                    }
                }
            }
            Divider()
        }
        Button(ids.count > 1 ? "\(ids.count) Mangayı Güncelle" : "Güncelle") {
            Task { @MainActor in await model.updateLibrary(mangaIDs: ids) }
        }
        categoriesMenu(ids)
        Button("Tümünü Okundu İşaretle") {
            Task { @MainActor in await model.setAllRead(ids, read: true) }
        }
        Button("Tümünü Okunmadı İşaretle") {
            Task { @MainActor in await model.setAllRead(ids, read: false) }
        }
        Divider()
        Button(ids.count > 1 ? "\(ids.count) Mangayı Kütüphaneden Kaldır…" : "Kütüphaneden Kaldır…", role: .destructive) {
            selection = Set(ids)
            confirmRemove = true
        }
    }
}

@MainActor
struct LibraryItem: View {
    let manga: Manga
    var selected = false

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
                .overlay(alignment: .topLeading) {
                    if manga.nbRecentChapters > 0 {
                        Text("YENİ")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.green, in: Capsule())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: selected ? 3 : 0)
                }
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            Text(manga.name)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .padding(.horizontal, selected ? 4 : 0)
                .background(selected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
            if let server = manga.serverName {
                Text(server)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(manga.name))
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if let server = manga.serverName { parts.append(server) }
        if manga.nbUnreadChapters > 0 { parts.append(String(localized: "\(manga.nbUnreadChapters) okunmamış bölüm")) }
        if manga.nbRecentChapters > 0 { parts.append(String(localized: "yeni bölüm var")) }
        return parts.joined(separator: ", ")
    }
}
