// SPDX-License-Identifier: GPL-3.0-or-later
//
// "A new version is available": compares the commit this app was built from
// (Info.plist KomikkuCommit) with the commit of the latest `nightly` release.

import Foundation

struct AvailableUpdate: Equatable {
    let title: String
    let pageURL: URL
    let commit: String
    /// Assets of the release (nil when missing: then only the page can be opened)
    let zipURL: URL?
    let checksumsURL: URL?
}

enum UpdateChecker {
    static let releaseAPI = URL(string: "https://api.github.com/repos/yunusemrecan/mekurimac/releases/tags/nightly")!
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
            return .unknown(String(localized: "Geliştirme sürümü: sürüm bilgisi yok"))
        }
        var request = URLRequest(url: releaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        // CI only: shared runners hit the anonymous API rate limit
        if let token = ProcessInfo.processInfo.environment["KOMIKKU_GITHUB_TOKEN"], !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 { AppLog.write("update: GitHub API answered \(status)") }
            guard status == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let target = json["target_commitish"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
                return .unknown(String(localized: "GitHub'dan sürüm bilgisi alınamadı"))
            }
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
            if target.hasPrefix(current) || current.hasPrefix(target) {
                return .upToDate
            }
            let assets = json["assets"] as? [[String: Any]] ?? []
            func asset(_ name: String) -> URL? {
                (assets.first { $0["name"] as? String == name }?["browser_download_url"] as? String)
                    .flatMap(URL.init(string:))
            }
            return .available(AvailableUpdate(
                title: json["name"] as? String ?? String(localized: "Yeni sürüm"), pageURL: page, commit: target,
                // releases before the rename are named Komikku-…
                zipURL: asset("Mekurimac-macos-arm64.zip") ?? asset("Komikku-macos-arm64.zip"), checksumsURL: asset("SHA256SUMS")
            ))
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
