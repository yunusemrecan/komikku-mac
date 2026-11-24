// SPDX-License-Identifier: GPL-3.0-or-later
//
// Backup / restore panels (File menu and Settings › General).

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum BackupUI {
    static let fileExtension = "komikku-backup"

    static func backup(_ model: AppModel) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Kütüphaneyi Yedekle")
        panel.message = String(localized: "Kütüphane, kategoriler, okuma geçmişi ve ayarlar tek dosyaya kaydedilir. İndirilen bölümler dahil değildir.")
        let day = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "Komikku \(day).\(fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.createBackup(at: url) }
    }

    static func restore(_ model: AppModel) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Yedekten Geri Yükle")
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .zip, .zip]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: "Yedek geri yüklensin mi?")
        alert.informativeText = String(localized: "Şu anki kütüphane, kategoriler, geçmiş ve ayarlar yedektekilerle değiştirilir. Mevcut veritabanının bir kopyası veri klasöründe saklanır. İndirilmiş bölüm dosyalarına dokunulmaz.")
        alert.addButton(withTitle: String(localized: "Geri Yükle"))
        alert.addButton(withTitle: String(localized: "Vazgeç"))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await model.restoreBackup(from: url) }
    }
}

@MainActor
struct BackupSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            HStack {
                Button("Yedekle…") { BackupUI.backup(model) }
                Button("Yedekten Geri Yükle…") { BackupUI.restore(model) }
            }
        } header: {
            Text("Yedekleme")
        } footer: {
            Text("Kütüphane, kategoriler, okuma geçmişi ve ayarlar. Başka bir Mac'e taşımak için de kullanılabilir.")
                .foregroundStyle(.secondary)
        }
    }
}
