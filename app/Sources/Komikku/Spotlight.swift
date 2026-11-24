// SPDX-License-Identifier: GPL-3.0-or-later
//
// Library mangas in Spotlight. Choosing a result opens the manga in Komikku.

import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

enum SpotlightIndex {
    static let domain = "komikku.library"
    static let enabledKey = "spotlight-enabled"
    private static let prefix = "manga-"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Only a real app bundle can register with Spotlight
    private static var available: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && CSSearchableIndex.isIndexingAvailable()
    }

    /// Replace the indexed set with the current library (cheap: a few hundred items at most).
    static func update(with library: [Manga]) {
        guard available else { return }
        let index = CSSearchableIndex.default()
        guard isEnabled else {
            index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
            return
        }

        let items: [CSSearchableItem] = library.map { manga in
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = manga.name
            attributes.displayName = manga.name
            var description = [String]()
            if let authors = manga.authors, !authors.isEmpty { description.append(authors.joined(separator: ", ")) }
            if let server = manga.serverName { description.append(server) }
            if manga.nbUnreadChapters > 0 { description.append(String(localized: "\(manga.nbUnreadChapters) okunmamış bölüm")) }
            attributes.contentDescription = description.joined(separator: " · ")
            attributes.keywords = ["manga", "komikku"] + (manga.genres ?? []) + (manga.authors ?? [])
            if let cover = manga.coverPath {
                attributes.thumbnailURL = URL(fileURLWithPath: cover)
            }
            let item = CSSearchableItem(uniqueIdentifier: prefix + String(manga.id),
                                        domainIdentifier: domain,
                                        attributeSet: attributes)
            item.expirationDate = .distantFuture
            return item
        }

        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(items) { error in
                AppLog.write(error.map { "spotlight: index failed: \($0.localizedDescription)" }
                             ?? "spotlight: indexed \(items.count) mangas")
            }
        }
    }

    /// Manga id from a Spotlight result's identifier
    static func mangaID(from identifier: String) -> Int? {
        guard identifier.hasPrefix(prefix) else { return nil }
        return Int(identifier.dropFirst(prefix.count))
    }
}
