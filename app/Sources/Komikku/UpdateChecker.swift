// SPDX-License-Identifier: GPL-3.0-or-later
//
// "A new version is available": compares the commit this app was built from
// (Info.plist KomikkuCommit) with the commit of the latest `nightly` release.

import Foundation

struct AvailableUpdate: Equatable {
    let title: String
    let pageURL: URL
}

enum UpdateChecker {
    static let releaseAPI = URL(string: "https://api.github.com/repos/yunusemrecan/komikku-mac/releases/tags/nightly")!
    static let lastCheckKey = "update-last-check"
    static let enabledKey = "check-updates"

    /// Commit the running app was built from (nil for development builds)
    static var bundledCommit: String? {
        guard let commit = Bundle.main.object(forInfoDictionaryKey: "KomikkuCommit") as? String,
              commit.count >= 7, !commit.hasPrefix("@") else { return nil }
        return commit
    }

    enum Result {
        case upToDate
        case available(AvailableUpdate)
        case unknown(String)
    }

    static func check() async -> Result {
        guard let current = bundledCommit else {
            return .unknown("Geliştirme sürümü: sürüm bilgisi yok")
        }
        var request = URLRequest(url: releaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let target = json["target_commitish"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
                return .unknown("GitHub'dan sürüm bilgisi alınamadı")
            }
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
            if target.hasPrefix(current) || current.hasPrefix(target) {
                return .upToDate
            }
            return .available(AvailableUpdate(title: json["name"] as? String ?? "Yeni sürüm", pageURL: page))
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    /// Automatic check at most every 12 hours
    static var isDue: Bool {
        let enabled = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        guard enabled else { return false }
        guard let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date else { return true }
        return Date().timeIntervalSince(last) > 12 * 3600
    }
}
