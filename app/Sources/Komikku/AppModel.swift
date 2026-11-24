// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum State: Equatable {
        case starting
        case ready
        case failed(String)
    }

    let backend = Backend()
    let webBridge = WebViewBridge()

    var state: State = .starting
    var library: [Manga] = [] {
        didSet {
            updateDockBadge()
            scheduleSpotlightUpdate()
        }
    }
    private var spotlightTask: Task<Void, Never>?

    /// Re-index Spotlight shortly after the library settles
    func scheduleSpotlightUpdate() {
        spotlightTask?.cancel()
        spotlightTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, state == .ready else { return }
            SpotlightIndex.update(with: library)
        }
    }
    /// Where the main window should go (set by notification clicks, links, Spotlight)
    var pendingNavigation: Route?
    /// A komikku:// link received before the app was ready
    var pendingURLAction: URLAction?
    /// Search to start in the global search view (from a komikku://search link)
    var pendingGlobalSearch: String?
    var pendingSidebar: SidebarItem?
    private var lastUpdatedMangaIDs: [Int] = []
    var servers: [ServerInfo] = []
    var languages: [String: String] = [:]
    var settings: [String: Any] = [:]
    var upstreamCommit: String?

    var isUpdatingLibrary = false
    var updateStatus: String?
    var errorMessage: String?
    var toast: String?
    private var toastTask: Task<Void, Never>?
    private var updateNewChapters = 0

    var downloads: [DownloadItem] = []
    var downloaderRunning = false
    var categories: [MangaCategory] = []

    /// Bumped whenever a manga's data changes, so open views can reload.
    var mangaRevision: [Int: Int] = [:]

    private init() {
        UserDefaults.standard.register(defaults: [
            MenuBarPreferences.autoUpdateHoursKey: 6,
            MenuBarPreferences.enabledKey: true,
            Self.readAheadKey: 2,
        ])
    }

    // MARK: - Startup

    func start() async {
        guard state != .ready else { return }
        backend.requestHandler = { [weak self] method, params in
            guard let self else { return nil }
            return try await self.webBridge.handle(method: method, params: params)
        }
        backend.notificationHandler = { [weak self] method, params in
            self?.handleNotification(method, params)
        }
        backend.terminationHandler = { [weak self] status in
            guard let self else { return }
            Task { await self.recoverFromCrash(status: status) }
        }

        AppLog.write("ui: language=\(Bundle.main.preferredLocalizations.first ?? "?") sample=\(String(localized: "Kütüphane"))")

        // Show the last known library immediately; Python starts meanwhile
        restoreUICache()

        do {
            try backend.start()
            try await backend.waitUntilReady()
            let hello = try await backend.callRaw("app.hello") as? [String: Any]
            upstreamCommit = hello?["upstream_commit"] as? String
            languages = try await backend.call("servers.languages")
            await reloadSettings()
            await reloadServers()
            await reloadLibrary()
            await reloadCategories()
            state = .ready
            saveUICache()
            _ = try? await backend.callRaw("library.fetch_missing_covers")
            if ProcessInfo.processInfo.environment["KOMIKKU_AUTOTEST_UPDATE"] != nil {
                // CI: install the published nightly over this copy and restart into it
                Task {
                    await checkForUpdates(manual: false)
                    AppLog.write("updatetest: available=\(availableUpdate != nil) canSelfUpdate=\(AppUpdater.canSelfUpdate)")
                    if availableUpdate != nil { installUpdate() }
                }
            } else if UpdateChecker.isDue {
                Task { await checkForUpdates(manual: false) }
            }
            requestNotificationPermission()
            _ = try? await backend.callRaw("downloads.resume_if_needed")
            await reloadDownloads()
            if settings["update-at-startup"] as? Bool == true {
                Task { await updateLibrary() }
            }
            startAutoUpdateLoop()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func shutdown() {
        saveUICache()
        backend.stop()
    }

    // MARK: - Instant start (UI cache)

    private func restoreUICache() {
        guard let cachedLibrary = UICache.load([Manga].self, from: "library") else { return }
        library = cachedLibrary
        categories = UICache.load([MangaCategory].self, from: "categories") ?? []
        servers = UICache.load([ServerInfo].self, from: "servers") ?? []
        languages = UICache.load([String: String].self, from: "languages") ?? [:]
        settings = UICache.loadDictionary(from: "settings") ?? [:]
        state = .ready
        AppLog.write("ui: library shown from cache (\(cachedLibrary.count) mangas)")
    }

    func saveUICache() {
        UICache.save(library, as: "library")
        UICache.save(categories, as: "categories")
        UICache.save(servers, as: "servers")
        UICache.save(languages, as: "languages")
        UICache.saveDictionary(settings, as: "settings")
    }

    // MARK: - App updates

    var availableUpdate: AvailableUpdate?
    /// In-app update in progress (download, verification, restart)
    var updateProgress: String?

    func checkForUpdates(manual: Bool) async {
        switch await UpdateChecker.check() {
        case .available(let update):
            availableUpdate = update
            AppLog.write("update: \(update.title) available")
        case .upToDate:
            availableUpdate = nil
            AppLog.write("update: up to date")
            if manual { showToast(String(localized: "Mekurimac güncel")) }
        case .unknown(let reason):
            AppLog.write("update: check failed: \(reason)")
            if manual { showToast(String(localized: "Güncelleme denetlenemedi: \(reason)")) }
        }
    }

    // MARK: - Backup / restore

    /// macOS-side preferences that go into a backup (window frames and caches excluded)
    private func exportablePreferences() -> [String: Any] {
        guard let id = Bundle.main.bundleIdentifier,
              let domain = UserDefaults.standard.persistentDomain(forName: id) else { return [:] }
        return domain.filter { key, value in
            !key.hasPrefix("NS") && !key.hasPrefix("Apple") && key != UpdateChecker.lastCheckKey
                && JSONSerialization.isValidJSONObject(["v": value])
        }
    }

    func createBackup(at url: URL) async {
        do {
            let result = try await backend.callRaw("backup.create", [
                "path": url.path, "app_preferences": exportablePreferences(),
            ]) as? [String: Any]
            let count = result?["library"] as? Int ?? 0
            AppLog.write("backup: \(url.path) (\(count) mangas)")
            showToast(String(localized: "Yedeklendi: \(count) manga"))
        } catch {
            report(error)
        }
    }

    /// Validates and stages the backup, then restarts the backend, which applies it.
    func restoreBackup(from url: URL) async {
        do {
            let staged = try await backend.callRaw("backup.stage_restore", ["path": url.path]) as? [String: Any]
            if let prefs = staged?["app_preferences"] as? [String: Any] {
                for (key, value) in prefs { UserDefaults.standard.set(value, forKey: key) }
            }
            AppLog.write("backup: restoring \(url.path)")
            await restartBackend()
            showToast(String(localized: "Yedek geri yüklendi"))
        } catch {
            report(error)
        }
    }

    /// Planned restart (no crash accounting): stop, start, reload everything.
    func restartBackend() async {
        backend.stop()
        do {
            try backend.start()
            try await backend.waitUntilReady()
            await reloadSettings()
            await reloadServers()
            await reloadLibrary()
            await reloadCategories()
            await reloadDownloads()
            for id in mangaRevision.keys { mangaRevision[id, default: 0] += 1 }
            updateDockBadge()
            _ = try? await backend.callRaw("library.fetch_missing_covers")
        } catch {
            state = .failed(String(localized: "Arka uç yeniden başlatılamadı: \(error.localizedDescription)"))
        }
    }

    // MARK: - Crash recovery

    private var crashTimes: [Date] = []

    /// The Python backend died unexpectedly: restart it (at most 3 times a minute)
    /// and reload what the UI shows. Pages that failed meanwhile show a retry button.
    private func recoverFromCrash(status: Int32) async {
        AppLog.write("backend exited unexpectedly (status \(status))")
        let now = Date()
        crashTimes = crashTimes.filter { now.timeIntervalSince($0) < 60 } + [now]
        guard crashTimes.count <= 3 else {
            state = .failed(String(localized: "Arka uç art arda çöktü (kod \(status)). Ayrıntılar: \(Backend.logURL.path)"))
            return
        }

        showToast(String(localized: "Arka uç yeniden başlatılıyor…"))
        isUpdatingLibrary = false
        do {
            try await Task.sleep(for: .milliseconds(500))
            try backend.start()
            try await backend.waitUntilReady()
            AppLog.write("backend restarted")
            await reloadSettings()
            await reloadServers()
            await reloadLibrary()
            await reloadCategories()
            _ = try? await backend.callRaw("downloads.resume_if_needed")
            await reloadDownloads()
            for id in mangaRevision.keys { mangaRevision[id, default: 0] += 1 }
            showToast(String(localized: "Arka uç yeniden başlatıldı"))
        } catch {
            state = .failed(String(localized: "Arka uç yeniden başlatılamadı: \(error.localizedDescription). Ayrıntılar: \(Backend.logURL.path)"))
        }
    }

    /// For testing crash recovery (KOMIKKU_AUTOTEST): kill the Python process.
    func simulateBackendCrash() {
        backend.killForTesting()
    }

    // MARK: - Notifications

    private func handleNotification(_ method: String, _ params: [String: Any]) {
        switch method {
        case "updater.begin":
            isUpdatingLibrary = true
            updateStatus = String(localized: "Güncelleniyor: \(params["name"] as? String ?? "")")
        case "updater.end":
            if let id = params["manga_id"] as? Int {
                mangaRevision[id, default: 0] += 1
                if (params["nb_recent_chapters"] as? Int ?? 0) > 0 && !lastUpdatedMangaIDs.contains(id) {
                    lastUpdatedMangaIDs.append(id)
                }
            }
            updateNewChapters += params["nb_recent_chapters"] as? Int ?? 0
        case "updater.finished":
            isUpdatingLibrary = false
            updateStatus = updateNewChapters > 0 ? String(localized: "\(updateNewChapters) yeni bölüm") : String(localized: "Güncelleme bitti")
            updateNewChapters = 0
            Task { await reloadLibrary() }

        case "downloads.changed":
            guard let id = params["id"] as? Int else { return }
            if let index = downloads.firstIndex(where: { $0.id == id }) {
                downloads[index].status = params["status"] as? String ?? downloads[index].status
                downloads[index].percent = (params["percent"] as? NSNumber)?.doubleValue ?? downloads[index].percent
                downloads[index].errors = params["errors"] as? Int
            } else {
                Task { await reloadDownloads() }
            }
        case "downloads.removed":
            if let chapterID = params["chapter_id"] as? Int {
                downloads.removeAll { $0.chapterId == chapterID }
            }
            if let mangaID = params["manga_id"] as? Int {
                mangaRevision[mangaID, default: 0] += 1
            }
        case "downloads.state":
            downloaderRunning = params["running"] as? Bool ?? false
            if !downloaderRunning { Task { await reloadDownloads() } }

        case "app.notification":
            let title = params["title"] as? String ?? "Mekurimac"
            let body = params["body"] as? String
            if settings["desktop-notifications"] as? Bool == true {
                postNotification(id: params["id"] as? String ?? UUID().uuidString, title: title, body: body)
            } else {
                showToast(body.map { "\(title): \($0)" } ?? title)
            }
        case "manga.cover_updated":
            if let id = params["manga_id"] as? Int, let path = params["cover_path"] as? String,
               let index = library.firstIndex(where: { $0.id == id }) {
                library[index].coverPath = path
                mangaRevision[id, default: 0] += 1
            }
        case "export.progress":
            let chapter = params["chapter"] as? Int ?? 1, chapters = params["chapters"] as? Int ?? 1
            let page = params["page"] as? Int ?? 0, pages = params["pages"] as? Int ?? 0
            exportStatus = chapters > 1
                ? String(localized: "Dışa aktarılıyor: bölüm \(chapter)/\(chapters), sayfa \(page)/\(pages)")
                : String(localized: "Dışa aktarılıyor: sayfa \(page)/\(pages)")
        case "app.toast":
            showToast(params["message"] as? String ?? "")
        default:
            break
        }
    }

    // MARK: - Toasts & desktop notifications

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { toast = nil }
        }
    }

    private var notificationsAvailable: Bool {
        // UNUserNotificationCenter requires a real app bundle (not `swift run`)
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private func requestNotificationPermission() {
        guard notificationsAvailable, settings["desktop-notifications"] as? Bool == true else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Dock badge

    func updateDockBadge() {
        let enabled = UserDefaults.standard.object(forKey: ReaderPreferences.dockBadgeKey) as? Bool ?? true
        let unread = library.reduce(0) { $0 + $1.nbUnreadChapters }
        NSApp?.dockTile.badgeLabel = enabled && unread > 0 ? "\(unread)" : nil
    }

    // MARK: - Notification clicks

    /// Notification ids come from upstream: "updater.<manga id>", "downloader.<manga id>",
    /// and "updater.0" for the end-of-update summary.
    func openNotification(id: String) {
        let mangaID = id.split(separator: ".").last.flatMap { Int($0) } ?? 0
        if mangaID > 0 {
            pendingNavigation = .manga(mangaID)
        } else if lastUpdatedMangaIDs.count == 1, let only = lastUpdatedMangaIDs.first {
            pendingNavigation = .manga(only)
        } else {
            pendingSidebar = .library
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func postNotification(id: String, title: String, body: String?) {
        guard notificationsAvailable else {
            showToast(title)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        if let body { content.body = body }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func setDesktopNotifications(_ enabled: Bool) async {
        await setSetting("desktop-notifications", enabled)
        if enabled { requestNotificationPermission() }
    }

    // MARK: - Downloads

    func reloadDownloads() async {
        do {
            let list: DownloadsList = try await backend.call("downloads.list")
            downloads = list.items
            downloaderRunning = list.running
        } catch {
            report(error)
        }
    }

    func download(_ chapterIDs: [Int], mangaID: Int) async {
        do {
            _ = try await backend.callRaw("downloads.add", ["chapter_ids": chapterIDs])
            await reloadDownloads()
        } catch {
            report(error)
        }
    }

    func cancelDownloads(_ chapterIDs: [Int]) async {
        do {
            _ = try await backend.callRaw("downloads.cancel", ["chapter_ids": chapterIDs])
            await reloadDownloads()
        } catch {
            report(error)
        }
    }

    func startDownloader() async {
        _ = try? await backend.callRaw("downloads.start")
        await reloadDownloads()
    }

    func stopDownloader() async {
        _ = try? await backend.callRaw("downloads.stop")
    }

    func download(forChapter chapterID: Int) -> DownloadItem? {
        downloads.first { $0.chapterId == chapterID }
    }

    // MARK: - Read-ahead downloads

    static let readAheadKey = "read-ahead-chapters"
    static let deleteFinishedKey = "delete-finished-downloads"

    /// Library mangas only: download the next N chapters of the one being read,
    /// and (optionally) delete the downloaded files of the chapter just finished.
    func readerOpenedChapter(manga: Manga, chapterID: Int, finished previous: Chapter?) {
        guard manga.inLibrary else { return }
        let ordered = manga.chaptersInReadingOrder
        let count = UserDefaults.standard.object(forKey: Self.readAheadKey) as? Int ?? 2
        if count > 0, let i = ordered.firstIndex(where: { $0.id == chapterID }) {
            let ahead = ordered.dropFirst(i + 1).prefix(count)
                .filter { !$0.downloaded && download(forChapter: $0.id) == nil }
                .map(\.id)
            AppLog.write("read-ahead: manga \(manga.id) chapter \(chapterID): queueing \(ahead.count) of the next \(count)")
            if !ahead.isEmpty {
                Task { await download(ahead, mangaID: manga.id) }
            }
        }
        if let previous, previous.id != chapterID, previous.downloaded,
           UserDefaults.standard.bool(forKey: Self.deleteFinishedKey) {
            AppLog.write("read-ahead: deleting finished chapter \(previous.id)")
            Task {
                // let the reader save the last pages read first
                try? await Task.sleep(for: .seconds(2))
                await clearDownloads([previous.id], mangaID: manga.id)
                await reloadLibrary()
            }
        }
    }

    // MARK: - Export (CBZ / PDF)

    var exportStatus: String?

    func exportChapters(_ chapterIDs: [Int], manga: Manga, format: String) {
        let ordered = manga.chaptersInReadingOrder.map(\.id).filter { chapterIDs.contains($0) }
        guard !ordered.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Dışa Aktarılacak Klasör")
        panel.prompt = String(localized: "Dışa Aktar")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task {
            exportStatus = String(localized: "Dışa aktarılıyor…")
            defer { exportStatus = nil }
            do {
                let paths = try await backend.callRaw("chapter.export", [
                    "chapter_ids": ordered, "format": format, "directory": directory.path,
                ]) as? [String] ?? []
                AppLog.write("export: \(paths.count) \(format) file(s) in \(directory.path)")
                showToast(String(localized: "\(paths.count) dosya dışa aktarıldı"))
                NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
            } catch {
                report(error)
            }
        }
    }

    // MARK: - Settings

    func reloadSettings() async {
        if let values = try? await backend.callRaw("settings.get") as? [String: Any] {
            settings = values
        }
    }

    func setSetting(_ key: String, _ value: Any) async {
        do {
            _ = try await backend.callRaw("settings.set", ["key": key, "value": value])
            settings[key] = value
        } catch {
            report(error)
        }
    }

    var defaultReadingMode: ReadingMode {
        ReadingMode(rawValue: settings["reading-mode"] as? String ?? "") ?? .rightToLeft
    }

    var serversLanguages: [String] {
        settings["servers-languages"] as? [String] ?? []
    }

    // MARK: - Servers

    func reloadServers() async {
        do {
            servers = try await backend.call("servers.list")
        } catch {
            report(error)
        }
    }

    var pinnedServers: [ServerInfo] {
        servers.filter(\.pinned).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func server(id: String) -> ServerInfo? {
        servers.first { $0.id == id }
    }

    func setPinned(_ server: ServerInfo, _ pinned: Bool) async {
        do {
            let _: [String] = try await backend.call("servers.set_pinned", ["server_id": server.id, "pinned": pinned])
            if let index = servers.firstIndex(where: { $0.id == server.id }) {
                servers[index].pinned = pinned
            }
        } catch {
            report(error)
        }
    }

    // MARK: - Library

    func reloadLibrary() async {
        do {
            library = try await backend.call("library.list")
            saveUICache()
        } catch {
            report(error)
        }
    }

    func updateLibrary(mangaIDs: [Int]? = nil) async {
        do {
            var params: [String: Any] = [:]
            if let mangaIDs { params["manga_ids"] = mangaIDs }
            let result = try await backend.callRaw("library.update", params) as? [String: Any]
            if result?["started"] as? Bool == true {
                isUpdatingLibrary = true
                UserDefaults.standard.set(Date(), forKey: MenuBarPreferences.lastAutoUpdateKey)
                updateNewChapters = 0
                lastUpdatedMangaIDs = []
                updateStatus = String(localized: "Güncelleniyor…")
            } else if result?["running"] as? Bool == true {
                showToast(String(localized: "Güncelleme zaten sürüyor"))
            } else {
                updateStatus = String(localized: "Güncellenecek manga yok")
            }
        } catch {
            updateStatus = nil
            report(error)
        }
    }

    // MARK: - Library options (stored in upstream settings)

    var librarySortOrder: LibrarySortOrder {
        LibrarySortOrder(rawValue: settings["library-sort-order"] as? String ?? "") ?? .latestReadDesc
    }

    var libraryFilters: Set<String> {
        Set(settings["library-selected-filters"] as? [String] ?? [])
    }

    func toggleLibraryFilter(_ key: String) async {
        var filters = libraryFilters
        if filters.contains(key) { filters.remove(key) } else { filters.insert(key) }
        await setSetting("library-selected-filters", Array(filters).sorted())
    }

    /// Library mangas for a category (nil = all, -1 = uncategorized), filtered and sorted.
    func libraryMangas(category: Int?, search: String) -> [Manga] {
        let filters = libraryFilters
        let term = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = library.filter { manga in
            if let category {
                let ids = manga.categories ?? []
                if category == -1 ? !ids.isEmpty : !ids.contains(category) { return false }
            }
            if !term.isEmpty {
                let inName = manga.name.lowercased().contains(term)
                let inServer = (manga.serverName ?? "").lowercased().contains(term)
                let inGenres = (manga.genres ?? []).contains { $0.lowercased() == term }
                if !(inName || inServer || inGenres) { return false }
            }
            if filters.contains("unread") && manga.nbUnreadChapters == 0 { return false }
            if filters.contains("downloaded") && (manga.nbDownloadedChapters ?? 0) == 0 { return false }
            if filters.contains("recents") && manga.nbRecentChapters == 0 { return false }
            return true
        }
        switch librarySortOrder {
        case .alphanumAsc:
            return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .latestReadDesc:
            return filtered.sorted { ($0.lastRead ?? "") > ($1.lastRead ?? "") }
        case .latestUpdatedDesc:
            return filtered.sorted { ($0.lastUpdate ?? "") > ($1.lastUpdate ?? "") }
        }
    }

    // MARK: - Categories

    func reloadCategories() async {
        do {
            categories = try await backend.call("categories.list")
        } catch {
            report(error)
        }
    }

    func createCategory(_ label: String) async {
        do {
            _ = try await backend.callRaw("categories.create", ["label": label])
            await reloadCategories()
        } catch {
            report(error)
        }
    }

    func renameCategory(_ id: Int, _ label: String) async {
        do {
            _ = try await backend.callRaw("categories.rename", ["category_id": id, "label": label])
            await reloadCategories()
        } catch {
            report(error)
        }
    }

    func deleteCategory(_ id: Int) async {
        _ = try? await backend.callRaw("categories.delete", ["category_id": id])
        await reloadCategories()
        await reloadLibrary()
    }

    func assign(_ mangaIDs: [Int], to categoryID: Int, _ active: Bool) async {
        _ = try? await backend.callRaw("categories.assign", ["manga_ids": mangaIDs, "category_id": categoryID, "active": active])
        await reloadLibrary()
        await reloadCategories()
        for id in mangaIDs { mangaRevision[id, default: 0] += 1 }
    }

    // MARK: - Bulk library actions

    func setAllRead(_ mangaIDs: [Int], read: Bool) async {
        _ = try? await backend.callRaw("manga.set_all_read", ["manga_ids": mangaIDs, "read": read])
        for id in mangaIDs { mangaRevision[id, default: 0] += 1 }
        await reloadLibrary()
    }

    func removeFromLibrary(_ mangaIDs: [Int]) async {
        _ = try? await backend.callRaw("manga.delete_many", ["manga_ids": mangaIDs])
        await reloadLibrary()
        await reloadCategories()
    }

    func addToLibrary(_ manga: Manga) async -> Manga? {
        do {
            let updated: Manga = try await backend.call("manga.add_to_library", ["manga_id": manga.id])
            await reloadLibrary()
            return updated
        } catch {
            report(error)
            return nil
        }
    }

    func removeFromLibrary(_ manga: Manga) async {
        do {
            _ = try await backend.callRaw("manga.delete", ["manga_id": manga.id])
            await reloadLibrary()
        } catch {
            report(error)
        }
    }

    // MARK: - Chapters

    func setRead(_ chapterIDs: [Int], read: Bool, mangaID: Int) async {
        do {
            _ = try await backend.callRaw("chapter.set_read", ["chapter_ids": chapterIDs, "read": read])
            mangaRevision[mangaID, default: 0] += 1
            await reloadLibrary()
        } catch {
            report(error)
        }
    }

    func clearDownloads(_ chapterIDs: [Int], mangaID: Int) async {
        do {
            _ = try await backend.callRaw("chapter.clear", ["chapter_ids": chapterIDs])
            mangaRevision[mangaID, default: 0] += 1
        } catch {
            report(error)
        }
    }

    // MARK: - Errors

    func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }
}
