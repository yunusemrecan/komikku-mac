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

    func start(chapterID: Int, defaultMode: ReadingMode) async {
        do {
            let manga: Manga = try await backend.call("manga.get", ["manga_id": mangaID])
            self.manga = manga
            mode = ReadingMode(rawValue: manga.readingMode ?? "") ?? defaultMode
            await open(chapterID: chapterID, atEnd: false)
        } catch {
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
            pageShown(index)
        } catch {
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
            guard chapter?.id == chapterID else { return }
            pagePaths[i] = path
        } catch {
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
            for ahead in 1...3 { await page(i + ahead) }
            await page(i - 1)
        }
    }

    // MARK: Navigation

    func pageShown(_ i: Int) {
        guard pageCount > 0 else { return }
        index = min(max(i, 0), pageCount - 1)
        prefetch(around: index)
        pendingRead.insert(index)
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
        if index + 1 < pageCount {
            pageShown(index + 1)
        } else if let next = nextChapter {
            Task { await open(chapterID: next.id, atEnd: false) }
        }
    }

    func previous() {
        if index > 0 {
            pageShown(index - 1)
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
    let target: ReaderTarget

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
                ProgressView().tint(.white)
            }
        }
        .navigationTitle(model?.title ?? "Okuyucu")
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .toolbar { toolbar }
        .task {
            let reader = ReaderModel(mangaID: target.mangaId, backend: app.backend)
            model = reader
            focused = true
            await reader.start(chapterID: target.chapterId, defaultMode: app.defaultReadingMode)
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
            ProgressView().tint(.white)
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
            Text("\(model.index + 1) / \(model.pageCount)")
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

                Menu {
                    Picker("Okuma Yönü", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                        ForEach(ReadingMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Okuma Yönü", systemImage: "book.pages")
                }
                .help("Okuma yönü")
            }
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard let model, model.mode != .webtoon || press.characters == "f" else {
            return .ignored
        }
        let rtl = model.mode == .rightToLeft

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
            if press.characters == "f" {
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
            PageImage(model: model, index: model.index, fit: .screen)
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

    @State private var image: NSImage?

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
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, minHeight: fit == .width ? 600 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fit == .screen ? .infinity : nil)
        .task(id: path) {
            guard let path else {
                image = nil
                await model.page(index)
                return
            }
            image = await ImageCache.shared.image(atPath: path)
        }
    }
}
