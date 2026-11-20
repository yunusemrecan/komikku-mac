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

    func start(chapterID: Int, defaultMode: ReadingMode, globalDoublePage: Bool) async {
        self.globalDoublePage = globalDoublePage
        AppLog.write("reader: start manga=\(mangaID) chapter=\(chapterID)")
        do {
            let manga: Manga = try await backend.call("manga.get", ["manga_id": mangaID])
            self.manga = manga
            mode = ReadingMode(rawValue: manga.readingMode ?? "") ?? defaultMode
            doublePageSetting = manga.doublePage.map { $0 == 1 } ?? globalDoublePage
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

    func recordAspect(_ i: Int, _ aspect: CGFloat) {
        if aspects[i] != aspect { aspects[i] = aspect }
    }

    func setDoublePage(_ value: Bool) {
        doublePageSetting = value
        let override: Any = value == globalDoublePage ? NSNull() : (value ? 1 : 0)
        Task {
            _ = try? await backend.callRaw("manga.update", ["manga_id": mangaID, "fields": ["double_page": override]])
        }
    }

    func pageShown(_ i: Int) {
        guard pageCount > 0 else { return }
        index = min(max(i, 0), pageCount - 1)
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
        let last = currentSpread.last ?? index
        if last + 1 < pageCount {
            pageShown(last + 1)
        } else if let next = nextChapter {
            Task { await open(chapterID: next.id, atEnd: false) }
        }
    }

    func previous() {
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

    @State private var model: ReaderModel?
    @State private var showControls = true
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let model {
                content(model)
                    .focusedSceneValue(\.reader, model)
            } else {
                LoadingLabel(text: "Açılıyor…")
            }
        }
        .environment(\.colorScheme, .dark)
        .navigationTitle(model?.title ?? "Okuyucu")
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .toolbar { toolbar }
        .task(id: target) {
            AppLog.write("reader: opened for \(target) embedded=\(embedded)")
            let reader = ReaderModel(mangaID: target.mangaId, backend: app.backend)
            model = reader
            focused = true
            await reader.start(chapterID: target.chapterId, defaultMode: app.defaultReadingMode,
                               globalDoublePage: app.settings["double-page"] as? Bool ?? false)
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
            .foregroundStyle(.white)
        } else if model.pageCount == 0 {
            LoadingLabel(text: model.loading ? "Bölüm yükleniyor…" : "Bu bölümde sayfa bulunamadı")
        } else if model.mode == .webtoon {
            WebtoonPager(model: model)
        } else {
            PagedPager(model: model)
                .overlay(alignment: .bottom) {
                    if showControls { pageBar(model) }
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

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard let model, model.mode != .webtoon || press.characters == "f" || press.key == .escape else {
            return .ignored
        }
        let rtl = model.mode == .rightToLeft

        if press.key == .escape {
            if NSApp.keyWindow?.styleMask.contains(.fullScreen) == true {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } else if embedded {
                dismiss()
            } else {
                return .ignored
            }
            return .handled
        }

        switch press.key {
        case .rightArrow:
            rtl ? model.previous() : model.next()
        case .leftArrow:
            rtl ? model.next() : model.previous()
        case .downArrow, .pageDown:
            model.next()
        case .upArrow, .pageUp:
            model.previous()
        case .space:
            press.modifiers.contains(.shift) ? model.previous() : model.next()
        case .home:
            model.pageShown(0)
        case .end:
            model.pageShown(model.pageCount - 1)
        default:
            if press.characters == "d" {
                if model.mode == .rightToLeft || model.mode == .leftToRight {
                    model.setDoublePage(!model.doublePageSetting)
                }
            } else if press.characters == "f" {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } else {
                return .ignored
            }
        }
        return .handled
    }
}

// MARK: - Paged mode

@MainActor
struct PagedPager: View {
    let model: ReaderModel

    var body: some View {
        GeometryReader { proxy in
            spreadView
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    // Click on the leading/trailing third turns pages, like a book
                    let third = proxy.size.width / 3
                    let rtl = model.mode == .rightToLeft
                    if location.x < third {
                        rtl ? model.next() : model.previous()
                    } else if location.x > proxy.size.width - third {
                        rtl ? model.previous() : model.next()
                    }
                }
        }
        .id(model.chapter?.id)
    }

    @ViewBuilder
    private var spreadView: some View {
        let spread = model.currentSpread
        if spread.count == 2 {
            // Right-to-left: the first page of the pair sits on the right, like a printed manga
            let rtl = model.mode == .rightToLeft
            let left = rtl ? spread[1] : spread[0]
            let right = rtl ? spread[0] : spread[1]
            HStack(spacing: 0) {
                PageImage(model: model, index: left, fit: .screen, alignment: .trailing)
                PageImage(model: model, index: right, fit: .screen, alignment: .leading)
            }
        } else {
            PageImage(model: model, index: model.index, fit: .screen)
        }
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
                    ForEach(0..<model.pageCount, id: \.self) { i in
                        PageImage(model: model, index: i, fit: .width)
                            .id(i)
                            .onAppear { model.pageShown(i) }
                    }

                    if let next = model.nextChapter {
                        Button {
                            Task { @MainActor in await model.open(chapterID: next.id, atEnd: false) }
                        } label: {
                            Label("Sonraki bölüm: \(next.title)", systemImage: "arrow.down.circle")
                                .padding()
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(40)
                    } else {
                        Text("Son bölüm")
                            .foregroundStyle(.secondary)
                            .padding(40)
                    }
                }
                .frame(maxWidth: 900)
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
            } else if model.failedPages.contains(index) {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Sayfa \(index + 1) yüklenemedi")
                    Button("Yeniden Dene") { model.retry(index) }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                LoadingLabel(text: decodeFailed ? "Sayfa \(index + 1) gösterilemedi" : "Sayfa \(index + 1) yükleniyor…")
                    .frame(maxWidth: .infinity, minHeight: fit == .width ? 600 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fit == .screen ? .infinity : nil, alignment: alignment)
        .task(id: path) {
            guard let path else {
                image = nil
                await model.page(index)
                return
            }
            image = await ImageCache.shared.image(atPath: path)
            decodeFailed = image == nil
            if let image {
                let rep = image.representations.first
                let width = CGFloat(rep?.pixelsWide ?? 0) > 0 ? CGFloat(rep!.pixelsWide) : image.size.width
                let height = CGFloat(rep?.pixelsHigh ?? 0) > 0 ? CGFloat(rep!.pixelsHigh) : image.size.height
                if height > 0 { model.recordAspect(index, width / height) }
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
            Text(text).foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
