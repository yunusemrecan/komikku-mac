// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

// MARK: - Model

@MainActor
@Observable
final class ReaderModel {
    let mangaID: Int
    private let backend: Backend

    var manga: Manga?
    var chapter: Chapter?
    var pageCount = 0
    var pagePaths: [Int: String] = [:]
    var failedPages: Set<Int> = []
    var index = 0
    var mode: ReadingMode = .rightToLeft
    /// Two pages side by side (paged left/right modes only)
    var doublePageSetting = false
    var coverAlone = UserDefaults.standard.object(forKey: ReaderPreferences.coverAloneKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(coverAlone, forKey: ReaderPreferences.coverAloneKey) }
    }
    /// width / height of pages whose image has been decoded
    var aspects: [Int: CGFloat] = [:]
    private var globalDoublePage = false

    // Appearance: per-manga override, else global setting (same keys as upstream)
    var scaling: PageScaling = .screen
    var background: ReaderBackground = .systemStyle
    var bordersCrop = false
    var bordersCropThreshold = 220
    var landscapeZoom = false
    var pageNumbering = true
    var filters = PageFilters(json: nil)
    var clampSize: CGFloat = 960
    var zoom: CGFloat = 1
    var pixelSizes: [Int: CGSize] = [:]
    /// Backing scroll views, driven by the keyboard
    let pagedScroll = ScrollHandle()
    let webtoonScroll = ScrollHandle()
    /// Last page turn went backwards: show the end of the new page (when it scrolls)
    var navigatedBackward = false
    /// Paged modes: the "chapter finished" screen shown after the last page
    var atChapterEnd = false
    /// Whether the displayed page/spread is larger than the window (set by PagedPager
    /// from its own size computation; drives arrow keys: pan vs. turn the page)
    @ObservationIgnored var overflowX = false
    @ObservationIgnored var overflowY = false
    private var globals: [String: Any] = [:]

    var loading = false
    var error: String?
    /// Incremented when a chapter finishes loading; webtoon view scrolls on change.
    var chapterToken = 0

    private var inFlight: Set<Int> = []
    private var pendingRead: Set<Int> = []
    private var readFlushTask: Task<Void, Never>?

    init(mangaID: Int, backend: Backend) {
        self.mangaID = mangaID
        self.backend = backend
    }

    var title: String {
        [manga?.name, chapter?.title].compactMap { $0 }.joined(separator: " — ")
    }

    var orderedChapters: [Chapter] { manga?.chaptersInReadingOrder ?? [] }

    var previousChapter: Chapter? {
        guard let chapter, let i = orderedChapters.firstIndex(where: { $0.id == chapter.id }), i > 0 else { return nil }
        return orderedChapters[i - 1]
    }

    var nextChapter: Chapter? {
        guard let chapter, let i = orderedChapters.firstIndex(where: { $0.id == chapter.id }),
              i + 1 < orderedChapters.count else { return nil }
        return orderedChapters[i + 1]
    }

    // MARK: Loading

    func start(chapterID: Int, defaultMode: ReadingMode, settings: [String: Any]) async {
        globals = settings
        self.globalDoublePage = settings["double-page"] as? Bool ?? false
        AppLog.write("reader: start manga=\(mangaID) chapter=\(chapterID)")
        do {
            let manga: Manga = try await backend.call("manga.get", ["manga_id": mangaID])
            self.manga = manga
            mode = ReadingMode(rawValue: manga.readingMode ?? "") ?? defaultMode
            doublePageSetting = manga.doublePage.map { $0 == 1 } ?? globalDoublePage
            applyAppearance(manga)
            if ProcessInfo.processInfo.environment["KOMIKKU_AUTOTEST_DOUBLE"] != nil {
                doublePageSetting = true
            }
            AppLog.write("reader: manga loaded, \(manga.chapters?.count ?? 0) chapters, mode=\(mode.rawValue)")
            await open(chapterID: chapterID, atEnd: false)
        } catch {
            AppLog.write("reader: manga.get failed: \(error)")
            self.error = error.localizedDescription
        }
    }

    func open(chapterID: Int, atEnd: Bool) async {
        flushReadPages()
        loading = true
        error = nil
        defer { loading = false }
        do {
            let load: ChapterLoad = try await backend.call("chapter.load", ["chapter_id": chapterID])
            chapter = orderedChapters.first { $0.id == chapterID }
            pageCount = load.nbPages ?? load.pagePaths.count
            pagePaths = [:]
            aspects = [:]
            pixelSizes = [:]
            zoom = 1
            failedPages = []
            inFlight = []
            for (i, path) in load.pagePaths.enumerated() {
                if let path { pagePaths[i] = path }
            }
            if atEnd {
                index = max(pageCount - 1, 0)
            } else if !load.read, let last = load.lastPageReadIndex, last < pageCount {
                index = last
            } else {
                index = 0
            }
            atChapterEnd = false
            chapterToken += 1
            AppLog.write("reader: chapter \(chapterID) loaded, pages=\(pageCount) cached=\(pagePaths.count) start=\(index)")
            pageShown(index)
        } catch {
            AppLog.write("reader: chapter.load \(chapterID) failed: \(error)")
            self.error = error.localizedDescription
        }
    }

    func page(_ i: Int) async {
        guard i >= 0, i < pageCount, pagePaths[i] == nil, !inFlight.contains(i), let chapterID = chapter?.id else { return }
        inFlight.insert(i)
        failedPages.remove(i)
        defer { inFlight.remove(i) }
        do {
            let path: String = try await backend.call("chapter.page", ["chapter_id": chapterID, "index": i])
            AppLog.write("reader: page \(i) -> \(path)")
            guard chapter?.id == chapterID else { return }
            pagePaths[i] = path
        } catch {
            AppLog.write("reader: page \(i) failed: \(error)")
            guard chapter?.id == chapterID else { return }
            failedPages.insert(i)
        }
    }

    func retry(_ i: Int) {
        failedPages.remove(i)
        Task { await page(i) }
    }

    /// Fetch the current page first, then a few ahead.
    func prefetch(around i: Int) {
        Task {
            await page(i)
            for ahead in 1...4 { await page(i + ahead) }
            await page(i - 1)
        }
    }

    // MARK: Navigation

    // MARK: Spreads

    var isDoublePage: Bool {
        doublePageSetting && (mode == .rightToLeft || mode == .leftToRight)
    }

    private func isWide(_ i: Int) -> Bool {
        (aspects[i] ?? 0) > 1.0
    }

    /// Pages grouped as displayed: singles, or pairs in double-page mode.
    /// The cover (optionally) and wide images stand alone; everything else pairs up in order.
    var spreads: [[Int]] {
        guard isDoublePage else { return (0..<pageCount).map { [$0] } }
        var result: [[Int]] = []
        var i = 0
        while i < pageCount {
            if (i == 0 && coverAlone) || isWide(i) || i + 1 >= pageCount || isWide(i + 1) {
                result.append([i])
                i += 1
            } else {
                result.append([i, i + 1])
                i += 2
            }
        }
        return result
    }

    var currentSpread: [Int] {
        spreads.first { $0.contains(index) } ?? [index]
    }

    func recordSize(_ i: Int, _ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if pixelSizes[i] != size { pixelSizes[i] = size }
        let aspect = size.width / size.height
        if aspects[i] != aspect { aspects[i] = aspect }
    }

    // MARK: Appearance

    private func applyAppearance(_ manga: Manga) {
        scaling = PageScaling(rawValue: manga.scaling ?? "")
            ?? PageScaling(rawValue: globals["scaling"] as? String ?? "") ?? .screen
        background = ReaderBackground(rawValue: manga.backgroundColor ?? "")
            ?? ReaderBackground(rawValue: globals["background-color"] as? String ?? "") ?? .systemStyle
        bordersCrop = manga.bordersCrop.map { $0 == 1 } ?? (globals["borders-crop"] as? Bool ?? false)
        bordersCropThreshold = manga.bordersCropThreshold ?? (globals["borders-crop-threshold"] as? Int ?? 220)
        landscapeZoom = manga.landscapeZoom.map { $0 == 1 } ?? (globals["landscape-zoom"] as? Bool ?? false)
        pageNumbering = manga.pageNumbering.map { $0 == 1 } ?? (globals["page-numbering"] as? Bool ?? true)
        filters = PageFilters(json: globals["page-filters"] as? String)
        clampSize = CGFloat(globals["clamp-size"] as? Int ?? 960)
    }

    /// Crop threshold to use for page images (nil = no crop; never in webtoon mode, like upstream)
    var cropThreshold: Int? {
        bordersCrop && mode != .webtoon ? bordersCropThreshold : nil
    }

    /// Store a per-manga override; cleared (NULL) when equal to the global default.
    private func persist(_ field: String, _ value: Any, equalsGlobal: Bool) {
        let payload: Any = equalsGlobal ? NSNull() : value
        Task {
            _ = try? await backend.callRaw("manga.update", ["manga_id": mangaID, "fields": [field: payload]])
        }
    }

    func setScaling(_ value: PageScaling) {
        scaling = value
        zoom = 1
        persist("scaling", value.rawValue, equalsGlobal: value.rawValue == globals["scaling"] as? String)
    }

    func setBackground(_ value: ReaderBackground) {
        background = value
        persist("background_color", value.rawValue, equalsGlobal: value.rawValue == globals["background-color"] as? String)
    }

    func setBordersCrop(_ value: Bool) {
        bordersCrop = value
        persist("borders_crop", value ? 1 : 0, equalsGlobal: value == (globals["borders-crop"] as? Bool ?? false))
    }

    func setBordersCropThreshold(_ value: Int) {
        bordersCropThreshold = value
        persist("borders_crop_threshold", value, equalsGlobal: value == (globals["borders-crop-threshold"] as? Int ?? 220))
    }

    func setLandscapeZoom(_ value: Bool) {
        landscapeZoom = value
        persist("landscape_zoom", value ? 1 : 0, equalsGlobal: value == (globals["landscape-zoom"] as? Bool ?? false))
    }

    func setPageNumbering(_ value: Bool) {
        pageNumbering = value
        persist("page_numbering", value ? 1 : 0, equalsGlobal: value == (globals["page-numbering"] as? Bool ?? true))
    }

    /// Page filters are global in upstream
    func setFilters(_ value: PageFilters) {
        filters = value
        let json = value.json
        globals["page-filters"] = json
        Task {
            await AppModel.shared.setSetting("page-filters", json)
        }
    }

    // MARK: Zoom

    func zoomIn() { zoom = min(zoom * 1.25, 8) }
    func zoomOut() { zoom = max(zoom / 1.25, 0.25) }
    func resetZoom() { zoom = 1 }

    func setDoublePage(_ value: Bool) {
        doublePageSetting = value
        let override: Any = value == globalDoublePage ? NSNull() : (value ? 1 : 0)
        Task {
            _ = try? await backend.callRaw("manga.update", ["manga_id": mangaID, "fields": ["double_page": override]])
        }
    }

    func pageShown(_ i: Int) {
        guard pageCount > 0 else { return }
        atChapterEnd = false
        let newIndex = min(max(i, 0), pageCount - 1)
        if newIndex != index && mode != .webtoon { zoom = 1 }
        index = newIndex
        prefetch(around: index)
        for page in currentSpread { pendingRead.insert(page) }
        readFlushTask?.cancel()
        readFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.flushReadPages()
        }
    }

    func flushReadPages() {
        guard !pendingRead.isEmpty, let chapterID = chapter?.id else { return }
        let indexes = Array(pendingRead)
        pendingRead.removeAll()
        Task {
            let updated: Chapter? = try? await backend.call(
                "chapter.mark_pages_read", ["chapter_id": chapterID, "indexes": indexes]
            )
            if let updated, var manga = self.manga, let i = manga.chapters?.firstIndex(where: { $0.id == updated.id }) {
                manga.chapters?[i] = updated
                self.manga = manga
            }
            AppModel.shared.mangaRevision[self.mangaID, default: 0] += 1
        }
    }

    func next() {
        navigatedBackward = false
        if atChapterEnd {
            // Second "next" on the end screen: go on to the next chapter
            if let next = nextChapter {
                Task { await open(chapterID: next.id, atEnd: false) }
            }
            return
        }
        let last = currentSpread.last ?? index
        if last + 1 < pageCount {
            pageShown(last + 1)
        } else {
            atChapterEnd = true
        }
    }

    func previous() {
        navigatedBackward = true
        if atChapterEnd {
            atChapterEnd = false
            return
        }
        let first = currentSpread.first ?? index
        if first > 0 {
            let target = first - 1
            pageShown(spreads.first { $0.contains(target) }?.first ?? target)
        } else if let previous = previousChapter {
            Task { await open(chapterID: previous.id, atEnd: true) }
        }
    }

    func goToNextChapter() {
        if let next = nextChapter { Task { await open(chapterID: next.id, atEnd: false) } }
    }

    func goToPreviousChapter() {
        if let previous = previousChapter { Task { await open(chapterID: previous.id, atEnd: false) } }
    }

    func setMode(_ newMode: ReadingMode) {
        mode = newMode
        Task {
            _ = try? await backend.callRaw("manga.update", ["manga_id": mangaID, "fields": ["reading_mode": newMode.rawValue]])
        }
    }
}

// MARK: - Menu commands for the focused reader window

struct ReaderActionsKey: FocusedValueKey {
    typealias Value = ReaderModel
}

extension FocusedValues {
    var reader: ReaderModel? {
        get { self[ReaderActionsKey.self] }
        set { self[ReaderActionsKey.self] = newValue }
    }
}

@MainActor
struct ReaderCommands: Commands {
    @FocusedValue(\.reader) private var reader

    var body: some Commands {
        CommandMenu("Okuyucu") {
            Button("Sonraki Bölüm") { reader?.goToNextChapter() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(reader?.nextChapter == nil)
            Button("Önceki Bölüm") { reader?.goToPreviousChapter() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(reader?.previousChapter == nil)
            Divider()
            Toggle("Çift Sayfa", isOn: Binding(
                get: { reader?.doublePageSetting ?? false },
                set: { reader?.setDoublePage($0) }
            ))
            .disabled(reader == nil || reader?.mode == .webtoon || reader?.mode == .vertical)
            Toggle("Kapak Sayfası Tek", isOn: Binding(
                get: { reader?.coverAlone ?? true },
                set: { reader?.coverAlone = $0 }
            ))
            .disabled(reader?.isDoublePage != true)
            Divider()
            Button("Yakınlaştır") { reader?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(reader == nil || reader?.mode == .webtoon)
            Button("Uzaklaştır") { reader?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(reader == nil || reader?.mode == .webtoon)
            Button("Gerçek Boyut") { reader?.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(reader == nil || reader?.mode == .webtoon)
            Divider()
            Picker("Okuma Yönü", selection: Binding(
                get: { reader?.mode ?? .rightToLeft },
                set: { reader?.setMode($0) }
            )) {
                ForEach(ReadingMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .disabled(reader == nil)
        }
    }
}

// MARK: - Window

@MainActor
struct ReaderView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let target: ReaderTarget
    var embedded = false

    @Environment(\.colorScheme) private var systemScheme
    @State private var model: ReaderModel?
    @State private var showControls = true
    @State private var showAppearance = false
    @FocusState private var focused: Bool

    private var background: ReaderBackground { model?.background ?? .systemStyle }

    var body: some View {
        ZStack {
            background.color(systemScheme).ignoresSafeArea()

            if let model {
                content(model)
                    .focusedSceneValue(\.reader, model)
            } else {
                LoadingLabel(text: "Açılıyor…")
            }
        }
        .environment(\.colorScheme, background.contentScheme(systemScheme))
        .background {
            // Separate reader windows remember their size and place
            if !embedded { WindowAutosave(name: "KomikkuReaderWindow") }
        }
        .navigationTitle(model?.title ?? "Okuyucu")
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: [.down, .repeat]) { press in handleKey(press) }
        .onReceive(NotificationCenter.default.publisher(for: .komikkuAutotestKey)) { note in
            runAutotestKey(note.object as? String ?? "")
        }
        .toolbar { toolbar }
        .task(id: target) {
            AppLog.write("reader: opened for \(target) embedded=\(embedded)")
            let reader = ReaderModel(mangaID: target.mangaId, backend: app.backend)
            model = reader
            focused = true
            await reader.start(chapterID: target.chapterId, defaultMode: app.defaultReadingMode,
                               settings: app.settings)
            if ProcessInfo.processInfo.environment["KOMIKKU_AUTOTEST_DOUBLE"] != nil {
                // CI: turn one spread so the screenshot shows a pair of pages
                try? await Task.sleep(for: .seconds(8))
                reader.next()
                try? await Task.sleep(for: .seconds(4))
                AppLog.write("reader: spread shown \(reader.currentSpread)")
            }
        }
        .onDisappear {
            model?.flushReadPages()
        }
    }

    @ViewBuilder
    private func content(_ model: ReaderModel) -> some View {
        if let error = model.error {
            ContentUnavailableView {
                Label("Bölüm yüklenemedi", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                if let chapter = model.chapter {
                    Button("Yeniden Dene") { Task { @MainActor in await model.open(chapterID: chapter.id, atEnd: false) } }
                }
            }
            .foregroundStyle(.primary)
        } else if model.pageCount == 0 {
            LoadingLabel(text: model.loading ? "Bölüm yükleniyor…" : "Bu bölümde sayfa bulunamadı")
        } else if model.mode == .webtoon {
            WebtoonPager(model: model)
        } else {
            PagedPager(model: model)
                .overlay {
                    if model.atChapterEnd {
                        ChapterEndView(model: model)
                            .background(background.color(systemScheme))
                    }
                }
                .overlay(alignment: .bottom) {
                    if showControls && model.pageNumbering && !model.atChapterEnd { pageBar(model) }
                }
                .onHover { inside in
                    withAnimation(.easeInOut(duration: 0.2)) { showControls = inside }
                }
        }
    }

    private func pageBar(_ model: ReaderModel) -> some View {
        HStack(spacing: 12) {
            Text(pageLabel(model))
                .monospacedDigit()
            if model.pageCount > 1 {
                Slider(
                    value: Binding(
                        get: { Double(model.index) },
                        set: { model.pageShown(Int($0.rounded())) }
                    ),
                    in: 0...Double(model.pageCount - 1),
                    step: 1
                )
                .environment(\.layoutDirection, model.mode == .rightToLeft ? .rightToLeft : .leftToRight)
                .frame(maxWidth: 360)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 14)
    }

    private func pageLabel(_ model: ReaderModel) -> String {
        let spread = model.currentSpread
        if spread.count == 2 {
            return "\(spread[0] + 1)–\(spread[1] + 1) / \(model.pageCount)"
        }
        return "\(model.index + 1) / \(model.pageCount)"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if let model {
                Button {
                    model.goToPreviousChapter()
                } label: {
                    Label("Önceki Bölüm", systemImage: "chevron.backward.2")
                }
                .disabled(model.previousChapter == nil)
                .help("Önceki bölüm (⌘[)")

                Button {
                    model.goToNextChapter()
                } label: {
                    Label("Sonraki Bölüm", systemImage: "chevron.forward.2")
                }
                .disabled(model.nextChapter == nil)
                .help("Sonraki bölüm (⌘])")

                Button {
                    showAppearance.toggle()
                } label: {
                    Label("Görünüm", systemImage: "slider.horizontal.3")
                }
                .help("Ölçekleme, arka plan, kırpma, filtreler")
                .popover(isPresented: $showAppearance, arrowEdge: .bottom) {
                    ReaderAppearancePanel(model: model)
                }

                Button {
                    model.setDoublePage(!model.doublePageSetting)
                } label: {
                    Label("Çift Sayfa", systemImage: model.doublePageSetting ? "book.fill" : "book")
                }
                .disabled(model.mode == .webtoon || model.mode == .vertical)
                .help("Çift sayfa görünümü (D)")

                Menu {
                    Picker("Okuma Yönü", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                        ForEach(ReadingMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle("Kapak sayfası tek", isOn: Binding(get: { model.coverAlone }, set: { model.coverAlone = $0 }))
                        .disabled(!model.isDoublePage)
                } label: {
                    Label("Okuma Yönü", systemImage: "book.pages")
                }
                .help("Okuma yönü")
            }
        }
    }

    /// CI: simulate a key in the reader and log whether the page turned.
    private func runAutotestKey(_ command: String) {
        guard let model, ProcessInfo.processInfo.environment["KOMIKKU_AUTOTEST"] != nil else { return }
        switch command {
        case "zoom":
            model.zoom = 2.5
            AppLog.write("keytest: zoomed to 2.5")
        case "unzoom":
            model.resetZoom()
        default:
            let before = model.index
            let key: KeyEquivalent = command == "left" ? .leftArrow : .rightArrow
            _ = pagedKey(key, [], false, model)
            let fits = !model.overflowX
            AppLog.write("keytest: \(command) fits=\(fits) turned=\(model.index != before) index \(before)->\(model.index)")
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard let model else { return .ignored }

        if press.key == .escape {
            guard press.phase == .down else { return .handled }
            if NSApp.keyWindow?.styleMask.contains(.fullScreen) == true {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } else if embedded {
                dismiss()
            } else {
                return .ignored
            }
            return .handled
        }

        // Single-shot letter keys (no repeat)
        if press.phase == .down {
            if press.characters == "f" {
                NSApp.keyWindow?.toggleFullScreen(nil)
                return .handled
            }
            if press.characters == "d" {
                if model.mode == .rightToLeft || model.mode == .leftToRight {
                    model.setDoublePage(!model.doublePageSetting)
                }
                return .handled
            }
        }

        return model.mode == .webtoon
            ? webtoonKey(press.key, press.modifiers, model)
            : pagedKey(press.key, press.modifiers, press.phase == .repeat, model)
    }

    /// Webtoon: the keyboard scrolls the strip, like a web page.
    private func webtoonKey(_ key: KeyEquivalent, _ modifiers: EventModifiers, _ model: ReaderModel) -> KeyPress.Result {
        let scroll = model.webtoonScroll
        let height = max(scroll.viewport.height, 200)
        let shift = modifiers.contains(.shift)

        switch key {
        case .downArrow:
            scroll.scroll(dy: height * 0.15)
        case .upArrow:
            scroll.scroll(dy: -height * 0.15)
        case .space:
            scroll.scroll(dy: (shift ? -1 : 1) * height * 0.9)
        case .pageDown:
            scroll.scroll(dy: height * 0.9)
        case .pageUp:
            scroll.scroll(dy: -height * 0.9)
        case .home:
            scroll.scrollToEdge(bottom: false, animated: true)
        case .end:
            scroll.scrollToEdge(bottom: true, animated: true)
        default:
            return .ignored
        }
        return .handled
    }

    /// Paged modes: when the page is larger than the window (zoom, fit width…),
    /// keys first move around the page and only turn it at the edge.
    private func pagedKey(_ key: KeyEquivalent, _ modifiers: EventModifiers, _ repeating: Bool,
                          _ model: ReaderModel) -> KeyPress.Result {
        let rtl = model.mode == .rightToLeft
        let scroll = model.pagedScroll
        let size = scroll.viewport
        let stepX = max(size.width, 200) * 0.2
        let stepY = max(size.height, 200) * 0.2
        let bigY = max(size.height, 200) * 0.9

        // Turn the page only on a fresh press, so holding a key just pans
        func turn(_ action: () -> Void) { if !repeating { action() } }

        // Page fits on screen in that direction: the key turns the page.
        // Page is larger (zoomed, fit width…): the key pans, and turns only at the edge.
        let panX = model.overflowX
        let panY = model.overflowY

        switch key {
        case .rightArrow:
            if !(panX && scroll.scroll(dx: stepX)) { turn { rtl ? model.previous() : model.next() } }
        case .leftArrow:
            if !(panX && scroll.scroll(dx: -stepX)) { turn { rtl ? model.next() : model.previous() } }
        case .downArrow:
            if !(panY && scroll.scroll(dy: stepY)) { turn { model.next() } }
        case .upArrow:
            if !(panY && scroll.scroll(dy: -stepY)) { turn { model.previous() } }
        case .space:
            if modifiers.contains(.shift) {
                if !(panY && scroll.scroll(dy: -bigY)) { turn { model.previous() } }
            } else {
                if !(panY && scroll.scroll(dy: bigY)) { turn { model.next() } }
            }
        case .pageDown:
            turn { model.next() }
        case .pageUp:
            turn { model.previous() }
        case .home:
            turn { model.pageShown(0) }
        case .end:
            turn { model.pageShown(model.pageCount - 1) }
        default:
            return .ignored
        }
        return .handled
    }
}

// MARK: - Paged mode

@MainActor
struct PagedPager: View {
    let model: ReaderModel
    @State private var pinchBase: CGFloat?

    /// Pages of the current spread, left to right on screen
    private var pages: [Int] {
        let spread = model.currentSpread
        return model.mode == .rightToLeft ? spread.reversed() : spread
    }

    private func aspect(_ i: Int) -> CGFloat {
        model.aspects[i] ?? 0.7
    }

    /// Displayed size of the spread for the scaling mode and zoom.
    private func contentSize(_ container: CGSize) -> CGSize {
        guard container.width > 0, container.height > 0 else { return container }
        let total = pages.reduce(0) { $0 + aspect($1) }   // width/height at equal heights
        var size: CGSize

        switch model.scaling {
        case .width:
            size = CGSize(width: container.width, height: container.width / total)
        case .height:
            size = CGSize(width: container.height * total, height: container.height)
        case .original:
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let known = pages.compactMap { model.pixelSizes[$0] }
            if known.count == pages.count {
                let height = (known.map(\.height).max() ?? 0) / scale
                size = CGSize(width: height * total, height: height)
            } else {
                size = fitSize(container, total)
            }
        case .screen:
            size = fitSize(container, total)
        }
        return CGSize(width: size.width * model.zoom, height: size.height * model.zoom)
    }

    private func showReadingStart(end: Bool) {
        let rtl = model.mode == .rightToLeft
        // Wait for the new content size to be laid out
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            model.pagedScroll.scrollToEdge(bottom: end, trailing: end ? !rtl : rtl)
        }
    }

    private func fitSize(_ container: CGSize, _ total: CGFloat) -> CGSize {
        if pages.count == 1 && total > 1 && model.landscapeZoom {
            // Wide page: fill the height and pan horizontally
            return CGSize(width: container.height * total, height: container.height)
        }
        if container.width / container.height > total {
            return CGSize(width: container.height * total, height: container.height)
        }
        return CGSize(width: container.width, height: container.width / total)
    }

    var body: some View {
        GeometryReader { proxy in
            let container = proxy.size
            let size = contentSize(container)
            let scrolls = size.width > container.width + 1 || size.height > container.height + 1

            ScrollView([.horizontal, .vertical], showsIndicators: scrolls) {
                HStack(spacing: 0) {
                    ForEach(pages, id: \.self) { i in
                        PageImage(model: model, index: i, fit: .screen)
                            .frame(width: size.height * aspect(i), height: size.height)
                    }
                }
                .frame(width: size.width, height: size.height)
                .frame(minWidth: container.width, minHeight: container.height)
                .background(ScrollViewFinder(handle: model.pagedScroll))
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .named("pager")) { location in
                    // Click on the leading/trailing third turns pages, like a book
                    let third = container.width / 3
                    let rtl = model.mode == .rightToLeft
                    if location.x < third {
                        rtl ? model.next() : model.previous()
                    } else if location.x > container.width - third {
                        rtl ? model.previous() : model.next()
                    }
                }
            }
            .scrollDisabled(!scrolls)
            .onChange(of: [size.width, size.height, container.width, container.height], initial: true) { _, _ in
                model.overflowX = size.width > container.width + 1
                model.overflowY = size.height > container.height + 1
            }
            .onChange(of: model.index) { _, _ in
                // New page: start where reading starts (top-right for right-to-left manga),
                // or at the end when paging backwards
                showReadingStart(end: model.navigatedBackward)
            }
            .onChange(of: model.zoom) { old, new in
                // Entering zoom from the fitted page: begin at the reading start
                if old == 1 && new != 1 { showReadingStart(end: false) }
            }
            .coordinateSpace(.named("pager"))
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        if pinchBase == nil { pinchBase = model.zoom }
                        model.zoom = min(max((pinchBase ?? 1) * value.magnification, 0.25), 8)
                    }
                    .onEnded { _ in pinchBase = nil }
            )
        }
        .id(model.chapter?.id)
    }
}

// MARK: - Webtoon mode

@MainActor
struct WebtoonPager: View {
    let model: ReaderModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ScrollViewFinder(handle: model.webtoonScroll)
                        .frame(height: 0)
                    ForEach(0..<model.pageCount, id: \.self) { i in
                        PageImage(model: model, index: i, fit: .width)
                            .id(i)
                            .onAppear { model.pageShown(i) }
                    }

                    ChapterEndView(model: model)
                        .frame(height: 360)
                }
                .frame(maxWidth: model.clampSize)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.chapterToken, initial: true) { _, _ in
                let start = model.index
                DispatchQueue.main.async {
                    proxy.scrollTo(start, anchor: .top)
                }
            }
        }
    }
}

// MARK: - Page

@MainActor
struct PageImage: View {
    enum Fit { case screen, width }

    let model: ReaderModel
    let index: Int
    let fit: Fit
    var alignment: Alignment = .center

    @State private var image: NSImage?
    @State private var decodeFailed = false

    private var path: String? { model.pagePaths[index] }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .modifier(PageActions(model: model, index: index, image: image))
            } else if model.failedPages.contains(index) {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Sayfa \(index + 1) yüklenemedi")
                    Button("Yeniden Dene") { model.retry(index) }
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                LoadingLabel(text: decodeFailed ? "Sayfa \(index + 1) gösterilemedi" : "Sayfa \(index + 1) yükleniyor…")
                    .frame(maxWidth: .infinity, minHeight: fit == .width ? 600 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fit == .screen ? .infinity : nil, alignment: alignment)
        .pageFilters(model.filters)
        .task(id: "\(path ?? "")#\(model.cropThreshold ?? -1)") {
            guard let path else {
                image = nil
                await model.page(index)
                return
            }
            image = await ImageCache.shared.image(atPath: path, cropThreshold: model.cropThreshold)
            decodeFailed = image == nil
            if let image {
                let rep = image.representations.first
                let width = CGFloat(rep?.pixelsWide ?? 0) > 0 ? CGFloat(rep!.pixelsWide) : image.size.width
                let height = CGFloat(rep?.pixelsHigh ?? 0) > 0 ? CGFloat(rep!.pixelsHigh) : image.size.height
                model.recordSize(index, CGSize(width: width, height: height))
                AppLog.write("reader: page \(index) displayed \(Int(image.size.width))x\(Int(image.size.height))")
            } else {
                AppLog.write("reader: page \(index) could not be decoded: \(path)")
            }
        }
    }
}

@MainActor
struct LoadingLabel: View {
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Notification.Name {
    static let komikkuAutotestKey = Notification.Name("komikku.autotest.key")
}

// MARK: - End of chapter

@MainActor
struct ChapterEndView: View {
    let model: ReaderModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Bölüm bitti")
                .font(.title2.bold())
            if let chapter = model.chapter {
                Text(chapter.title)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            if let next = model.nextChapter {
                Divider().frame(width: 220).padding(.vertical, 4)
                Text("Sıradaki").font(.caption).foregroundStyle(.secondary)
                Text(next.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Button {
                    model.goToNextChapter()
                } label: {
                    Label("Sonraki Bölümü Oku", systemImage: "arrow.forward.circle")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                if model.mode != .webtoon {
                    Text(nextKeyHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Bu, şimdilik son bölüm.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var nextKeyHint: String {
        model.mode == .rightToLeft
            ? "← ya da Boşluk: sonraki bölüm  ·  →: son sayfaya dön"
            : "→ ya da Boşluk: sonraki bölüm  ·  ←: son sayfaya dön"
    }
}
