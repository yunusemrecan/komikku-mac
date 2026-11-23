// SPDX-License-Identifier: GPL-3.0-or-later
//
// Last known library / servers / settings, saved by the app so the main window
// can show the library instantly at launch while Python is still starting.

import Foundation

enum UICache {
    private static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Komikku-mac/ui-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func save<T: Encodable>(_ value: T, as name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: dir.appendingPathComponent("\(name).json"), options: .atomic)
    }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(name).json")) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func saveDictionary(_ value: [String: Any], as name: String) {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        try? data.write(to: dir.appendingPathComponent("\(name).json"), options: .atomic)
    }

    static func loadDictionary(from name: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(name).json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
