// SPDX-License-Identifier: GPL-3.0-or-later
//
// komikku:// links — usable from the Shortcuts app ("Open URLs"), Terminal (`open`),
// Raycast/Alfred, other apps…

import AppKit
import Foundation

enum URLAction: Equatable {
    case update
    case continueReading
    case search(String)
    case manga(Int)
    case show(SidebarItem)

    init?(url: URL) {
        guard url.scheme?.lowercased() == "komikku" else { return nil }
        let host = (url.host ?? "").lowercased()
        let path = url.pathComponents.filter { $0 != "/" }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func param(_ name: String) -> String? { query.first { $0.name == name }?.value }

        switch host {
        case "update": self = .update
        case "continue": self = .continueReading
        case "search":
            guard let term = param("q") ?? path.first, !term.isEmpty else { return nil }
            self = .search(term)
        case "manga":
            guard let id = (path.first ?? param("id")).flatMap(Int.init) else { return nil }
            self = .manga(id)
        case "library": self = .show(.library)
        case "history": self = .show(.history)
        case "downloads": self = .show(.downloads)
        case "stats": self = .show(.stats)
        default: return nil
        }
    }

    static func copyLink(forManga id: Int) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("komikku://manga/\(id)", forType: .string)
        AppModel.shared.showToast("Bağlantı kopyalandı: komikku://manga/\(id)")
    }

    /// Documentation shown in Settings > Kısayollar
    static let examples: [(url: String, label: String)] = [
        ("komikku://continue", "En son okunan mangaya kaldığın yerden devam et"),
        ("komikku://update", "Kütüphaneyi güncelle (yeni bölümleri denetle)"),
        ("komikku://search?q=one%20piece", "Tüm kaynaklarda ara"),
        ("komikku://library", "Kütüphaneyi aç"),
        ("komikku://history", "Geçmişi aç"),
        ("komikku://downloads", "İndirmeleri aç"),
        ("komikku://stats", "İstatistikleri aç"),
        ("komikku://manga/42", "Belirli bir mangayı aç (bağlantısı: mangaya sağ tık → Kısayol Bağlantısını Kopyala)"),
    ]
}
