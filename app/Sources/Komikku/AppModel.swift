// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Observation

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
    var library: [Manga] = []
    var servers: [ServerInfo] = []
    var languages: [String: String] = [:]
    var settings: [String: Any] = [:]
    var upstreamCommit: String?

    var isUpdatingLibrary = false
    var updateStatus: String?
    var downloadProgress: [Int: Double] = [:]   // chapter id -> 0...1
    var errorMessage: String?

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
            self?.state = .failed("Arka uç beklenmedik şekilde kapandı (kod \(status)). Ayrıntılar: \(Backend.logURL.path)")
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
            state = .ready
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

    // MARK: - Notifications

    private func handleNotification(_ method: String, _ params: [String: Any]) {
        switch method {
        case "library.update_progress":
            let index = (params["index"] as? Int ?? 0) + 1
            let count = params["count"] as? Int ?? 0
            let name = params["name"] as? String ?? ""
            updateStatus = "Güncelleniyor (\(index)/\(count)): \(name)"
        case "library.manga_updated":
            if let id = params["manga_id"] as? Int {
                mangaRevision[id, default: 0] += 1
            }
        case "chapter.download_progress":
            if let id = params["chapter_id"] as? Int,
               let index = params["index"] as? Int,
               let count = params["count"] as? Int, count > 0 {
                downloadProgress[id] = Double(index) / Double(count)
            }
        default:
            break
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
        } catch {
            report(error)
        }
    }

    func updateLibrary() async {
        guard !isUpdatingLibrary else { return }
        isUpdatingLibrary = true
        updateStatus = "Güncelleniyor…"
        defer {
            isUpdatingLibrary = false
        }
        do {
            let result = try await backend.callRaw("library.update") as? [String: Any]
            let count = result?["nb_new_chapters"] as? Int ?? 0
            updateStatus = count > 0 ? "\(count) yeni bölüm" : "Yeni bölüm yok"
            await reloadLibrary()
        } catch {
            updateStatus = nil
            report(error)
        }
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

    func download(_ chapterIDs: [Int], mangaID: Int) async {
        for id in chapterIDs {
            downloadProgress[id] = 0
            do {
                _ = try await backend.callRaw("chapter.download", ["chapter_id": id])
            } catch {
                report(error)
            }
            downloadProgress[id] = nil
            mangaRevision[mangaID, default: 0] += 1
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
