// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct ServerInfo: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let lang: String
    let description: String?
    let baseUrl: String?
    let isNsfw: Bool
    let isNsfwOnly: Bool
    let hasLogin: Bool
    let logoUrl: String?
    let logoPath: String?
    let trueSearch: Bool
    let hasLatest: Bool
    let hasPopular: Bool
    var pinned: Bool
}

/// Item returned by search / latest / popular. Servers may add extra keys; we keep the useful ones.
struct SearchResult: Codable, Identifiable, Hashable {
    let slug: String
    let name: String
    let cover: String?
    let url: String?
    let lastChapter: String?

    var id: String { slug }

    enum CodingKeys: String, CodingKey {
        case slug, name, cover, url, lastChapter
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        name = (try? c.decode(String.self, forKey: .name)) ?? slug
        cover = try? c.decodeIfPresent(String.self, forKey: .cover)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        // `last_chapter` may be a number or a string depending on the server
        if let s = try? c.decodeIfPresent(String.self, forKey: .lastChapter) {
            lastChapter = s
        } else if let d = try? c.decodeIfPresent(Double.self, forKey: .lastChapter) {
            lastChapter = d.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(d)) : String(d)
        } else {
            lastChapter = nil
        }
    }
}

struct Chapter: Codable, Identifiable, Hashable {
    let id: Int
    let mangaId: Int
    let slug: String
    let title: String
    let date: String?
    let num: String?
    let numVolume: String?
    let rank: Int
    var downloaded: Bool
    var recent: Bool
    var read: Bool
    var readProgress: String?
    var lastPageReadIndex: Int?
    let nbPages: Int?
}

struct Manga: Codable, Identifiable, Hashable {
    let id: Int
    let slug: String
    let serverId: String
    let serverName: String?
    let name: String
    let authors: [String]?
    let genres: [String]?
    let synopsis: String?
    let status: String?
    var inLibrary: Bool
    let lastRead: String?
    var readingMode: String?
    let coverPath: String?
    let path: String?
    let nbUnreadChapters: Int
    let nbRecentChapters: Int
    var chapters: [Chapter]?

    /// Synopsis comes as Pango markup from upstream; strip tags for display.
    var plainSynopsis: String? {
        guard let synopsis else { return nil }
        let stripped = synopsis.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return stripped
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Chapters in reading order (upstream `rank` ascending = oldest first).
    var chaptersInReadingOrder: [Chapter] {
        (chapters ?? []).sorted { $0.rank < $1.rank }
    }

    /// Chapter to open with "Continue reading".
    var resumeChapter: Chapter? {
        let ordered = chaptersInReadingOrder
        if let started = ordered.first(where: { !$0.read && $0.lastPageReadIndex != nil }) {
            return started
        }
        return ordered.first(where: { !$0.read }) ?? ordered.last
    }
}

struct ChapterLoad: Codable {
    let id: Int
    let nbPages: Int?
    let lastPageReadIndex: Int?
    let read: Bool
    let pagePaths: [String?]
}

struct MangaRefresh: Codable {
    let manga: Manga
}

enum ReadingMode: String, CaseIterable, Identifiable {
    case rightToLeft = "right-to-left"
    case leftToRight = "left-to-right"
    case vertical = "vertical"
    case webtoon = "webtoon"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rightToLeft: return "Sağdan sola"
        case .leftToRight: return "Soldan sağa"
        case .vertical: return "Dikey (sayfalı)"
        case .webtoon: return "Webtoon (kesintisiz)"
        }
    }

    var isPaged: Bool { self != .webtoon }
}

/// Value used to open a reader window.
struct ReaderTarget: Codable, Hashable {
    let mangaId: Int
    let chapterId: Int
}

enum SidebarItem: Hashable {
    case library
    case allServers
    case server(String)
}
