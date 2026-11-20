// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running from `swift run` (no bundle) still needs a regular, focusable app
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
}

@main
struct KomikkuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("Komikku", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 520)
        }
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
        .commands {
            ReaderCommands()
        }

        Settings {
            SettingsView()
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
            Button("Arka Uç Günlüğünü Göster") {
                NSWorkspace.shared.activateFileViewerSelecting([Backend.logURL])
            }
        }
    }
}
