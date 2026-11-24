// SPDX-License-Identifier: GPL-3.0-or-later
//
// Menu bar item (unread count, mangas with new chapters, quick actions) and the
// periodic library update that keeps running while the main window is closed.

import AppKit
import SwiftUI

enum MenuBarPreferences {
    static let enabledKey = "menu-bar-extra"
    static let autoUpdateHoursKey = "auto-update-hours"
    static let lastAutoUpdateKey = "auto-update-last"
}

@MainActor
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var unread: Int { model.library.reduce(0) { $0 + $1.nbUnreadChapters } }

    /// Mangas with new chapters first, then other unread ones
    private var mangas: [Manga] {
        model.library
            .filter { $0.nbUnreadChapters > 0 }
            .sorted {
                ($0.nbRecentChapters, $0.lastUpdate ?? "") > ($1.nbRecentChapters, $1.lastUpdate ?? "")
            }
            .prefix(8)
            .map { $0 }
    }

    private func open(_ link: String) {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    var body: some View {
        if model.isUpdatingLibrary {
            Text(model.updateStatus ?? String(localized: "Güncelleniyor…"))
        } else {
            Text(unread > 0 ? String(localized: "\(unread) okunmamış bölüm") : String(localized: "Okunmamış bölüm yok"))
        }

        if !mangas.isEmpty {
            Divider()
            ForEach(mangas) { manga in
                Button {
                    open("komikku://manga/\(manga.id)")
                } label: {
                    Text(manga.nbRecentChapters > 0
                         ? "\(manga.name) — \(String(localized: "\(manga.nbRecentChapters) yeni"))"
                         : "\(manga.name) — \(manga.nbUnreadChapters)")
                }
            }
        }

        Divider()
        Button("Kaldığın Yerden Devam Et") { open("komikku://continue") }
            .keyboardShortcut("c")
        Button("Kütüphaneyi Güncelle") { Task { await model.updateLibrary() } }
            .keyboardShortcut("r")
            .disabled(model.isUpdatingLibrary || model.state != .ready)
        Button("Mekurimac'ı Aç") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")
        Divider()
        SettingsLink { Text("Ayarlar…") }
            .keyboardShortcut(",")
        Button("Mekurimac'tan Çık") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let unread = model.library.reduce(0) { $0 + $1.nbUnreadChapters }
        HStack(spacing: 3) {
            Image(systemName: model.isUpdatingLibrary ? "arrow.triangle.2.circlepath" : "books.vertical")
            if unread > 0 { Text("\(unread)").monospacedDigit() }
        }
        .accessibilityLabel(Text("Mekurimac: \(unread) okunmamış bölüm"))
    }
}

extension AppModel {
    /// Checks every 10 minutes whether the periodic library update is due.
    func startAutoUpdateLoop() {
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .seconds(600))
                let hours = UserDefaults.standard.integer(forKey: MenuBarPreferences.autoUpdateHoursKey)
                guard hours > 0, state == .ready, !isUpdatingLibrary else { continue }
                let last = UserDefaults.standard.object(forKey: MenuBarPreferences.lastAutoUpdateKey) as? Date ?? .distantPast
                guard Date().timeIntervalSince(last) >= Double(hours) * 3600 else { continue }
                UserDefaults.standard.set(Date(), forKey: MenuBarPreferences.lastAutoUpdateKey)
                AppLog.write("auto-update: every \(hours) h, starting")
                await updateLibrary()
            }
        }
    }
}
