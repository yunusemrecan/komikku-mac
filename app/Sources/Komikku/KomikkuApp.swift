// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running from `swift run` (no bundle) still needs a regular, focusable app
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().delegate = self
        }
        Task { @MainActor in
            await AppModel.shared.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.shutdown()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Show banners even while the app is in front
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    // Clicking a notification opens the related manga (or the library)
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        Task { @MainActor in
            AppModel.shared.openNotification(id: id)
            completionHandler()
        }
    }
}

@main
struct KomikkuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared
    @AppStorage(MenuBarPreferences.enabledKey) private var showMenuBarItem = true

    var body: some Scene {
        // A single main window: links and Spotlight results always land in it
        Window("Komikku", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 520)
        }
        .handlesExternalEvents(matching: ["*"])
        .commands {
            KomikkuCommands(model: model)
        }

        WindowGroup("Okuyucu", id: "reader", for: ReaderTarget.self) { $target in
            if let target {
                ReaderView(target: target)
                    .environment(model)
            }
        }
        .defaultSize(width: 900, height: 1000)
        .handlesExternalEvents(matching: ["komikku-reader-window"])
        .commands {
            ReaderCommands()
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra(isInserted: $showMenuBarItem) {
            MenuBarContent()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
    }
}

// MARK: - Menus

/// Focused-value plumbing so menu items act on the main window's navigation.
struct NavigationActionsKey: FocusedValueKey {
    typealias Value = NavigationActions
}

struct NavigationActions {
    var showLibrary: () -> Void
    var showServers: () -> Void
    var showGlobalSearch: () -> Void
    var focusSearch: () -> Void
}

extension FocusedValues {
    var navigationActions: NavigationActions? {
        get { self[NavigationActionsKey.self] }
        set { self[NavigationActionsKey.self] = newValue }
    }
}

@MainActor
struct KomikkuCommands: Commands {
    let model: AppModel
    @FocusedValue(\.navigationActions) private var navigation

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandGroup(after: .newItem) {
            Button("Kütüphaneyi Yedekle…") { BackupUI.backup(model) }
                .disabled(model.state != .ready)
            Button("Yedekten Geri Yükle…") { BackupUI.restore(model) }
                .disabled(model.state != .ready)
        }

        CommandGroup(after: .appInfo) {
            Button("Güncellemeleri Denetle…") {
                Task { await model.checkForUpdates(manual: true) }
            }
        }

        CommandMenu("Kütüphane") {
            Button("Kütüphaneyi Güncelle") {
                Task { await model.updateLibrary() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isUpdatingLibrary || model.state != .ready)
        }

        CommandGroup(before: .sidebar) {
            Button("Kütüphane") { navigation?.showLibrary() }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(navigation == nil)
            Button("Sunucular") { navigation?.showServers() }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(navigation == nil)
            Divider()
        }

        CommandGroup(after: .textEditing) {
            Button("Ara") { navigation?.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(navigation == nil)
            Button("Tüm Kaynaklarda Ara") { navigation?.showGlobalSearch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(navigation == nil)
        }

        CommandGroup(replacing: .help) {
            Button("Komikku Web Sitesi") {
                NSWorkspace.shared.open(URL(string: "https://codeberg.org/valos/Komikku")!)
            }
            Button("Sorun Bildir…") { IssueReport.present(model: model) }
            Button("Günlükleri Finder'da Göster") {
                NSWorkspace.shared.activateFileViewerSelecting([Backend.logURL, AppLog.url])
            }
        }
    }
}
