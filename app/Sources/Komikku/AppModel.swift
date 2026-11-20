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
        didSet { updateDockBadge() }
    }
    /// Where the main window should go (set by notification clicks)
    var pendingNavigation: Route?
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

    private init() {}

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
            requestNotificationPermission()
            _ = try? await backend.callRaw("downloads.resume_if_needed")
            await reloadDownloads()
            if settings["update-at-startup"] as? Bool == true {
                Task { await updateLibrary() }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func shutdown() {
        backend.stop()
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
            state = .failed("Arka uç art arda çöktü (kod \(status)). Ayrıntılar: \(Backend.logURL.path)")
            return
        }

        showToast("Arka uç yeniden başlatılıyor…")
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
            showToast("Arka uç yeniden başlatıldı")
        } catch {
            state = .failed("Arka uç yeniden başlatılamadı: \(error.localizedDescription). Ayrıntılar: \(Backend.logURL.path)")
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
            updateStatus = "Güncelleniyor: \(params["name"] as? String ?? "")"
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
            updateStatus = updateNewChapters > 0 ? "\(updateNewChapters) yeni bölüm" : "Güncelleme bitti"
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
            let title = params["title"] as? String ?? "Komikku"
            let body = params["body"] as? String
            if settings["desktop-notifications"] as? Bool == true {
                postNotification(id: params["id"] as? String ?? UUID().uuidString, title: title, body: body)
            } else {
                showToast(body.map { "\(title): \($0)" } ?? title)
            }
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
                updateNewChapters = 0
                lastUpdatedMangaIDs = []
                updateStatus = "Güncelleniyor…"
            } else if result?["running"] as? Bool == true {
                showToast("Güncelleme zaten sürüyor")
            } else {
                updateStatus = "Güncellenecek manga yok"
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
