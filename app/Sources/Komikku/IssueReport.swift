// SPDX-License-Identifier: GPL-3.0-or-later
//
// Help › Report a Problem: opens a pre-filled GitHub issue with version info and
// the end of the logs. The text is shown (and editable) before anything is sent;
// nothing leaves the Mac until the user submits the issue on GitHub.

import AppKit

@MainActor
enum IssueReport {
    static let newIssueURL = "https://github.com/yunusemrecan/komikku-mac/issues/new"

    /// Last `count` lines of a log file, with the home folder path hidden.
    static func tail(_ url: URL, lines count: Int) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return String(localized: "(yok)") }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(count)
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    static func body(model: AppModel) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let commit = (info["KomikkuCommit"] as? String).map { String($0.prefix(8)) } ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var machine = utsname()
        uname(&machine)
        let arch = withUnsafeBytes(of: &machine.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let language = Locale.preferredLanguages.first ?? "?"

        return """
        ### \(String(localized: "Ne oldu?"))



        ### \(String(localized: "Ne olmasını bekliyordun?"))



        ### \(String(localized: "Nasıl tekrarlanır?"))
        1.

        ---
        | | |
        |---|---|
        | Komikku for macOS | \(version) (\(build)), commit `\(commit)` |
        | Upstream Komikku | `\(model.upstreamCommit ?? "?")` |
        | macOS | \(os), \(arch) |
        | Language | \(language) |

        <details><summary>app.log</summary>

        ```
        \(tail(AppLog.url, lines: 40))
        ```
        </details>

        <details><summary>backend.log</summary>

        ```
        \(tail(Backend.logURL, lines: 40))
        ```
        </details>
        """
    }

    static func present(model: AppModel) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Sorun Bildir")
        alert.informativeText = String(localized: "GitHub'da yeni bir sorun kaydı açılır. Aşağıdaki metin (sürüm bilgisi ve günlüklerin sonu) kayda eklenir; istemediğin kısmı silebilirsin. Göndermek için GitHub hesabı gerekir.")
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 520, height: 260)
        if let text = scroll.documentView as? NSTextView {
            text.string = body(model: model)
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.isRichText = false
        }
        alert.accessoryView = scroll
        alert.addButton(withTitle: String(localized: "GitHub'da Aç"))
        alert.addButton(withTitle: String(localized: "Vazgeç"))
        guard alert.runModal() == .alertFirstButtonReturn,
              let text = (scroll.documentView as? NSTextView)?.string else { return }
        open(body: text)
    }

    static func open(body: String) {
        // Browsers and GitHub cut very long URLs: keep the body under ~6000 characters
        var body = body
        if body.count > 6000 {
            body = String(body.prefix(6000)) + "\n…\n```\n</details>"
        }
        var components = URLComponents(string: newIssueURL)!
        components.queryItems = [URLQueryItem(name: "body", value: body)]
        if let url = components.url {
            AppLog.write("issue: opening GitHub issue form (\(body.count) chars)")
            NSWorkspace.shared.open(url)
        }
    }
}
