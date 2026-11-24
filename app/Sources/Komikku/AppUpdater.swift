// SPDX-License-Identifier: GPL-3.0-or-later
//
// In-app update: downloads the release ZIP, checks it against the release's
// SHA256SUMS, checks the new app's signature, bundle id and build commit, then
// swaps the app bundle after the app quits and starts the new version.
//
// Falls back to opening the release page when the app cannot replace itself
// (read-only location, run from the disk image / App Translocation, dev build).

import AppKit
import CryptoKit
import Foundation

@MainActor
enum AppUpdater {
    enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let m): return m }
        }
    }

    /// Whether this copy of the app can replace itself
    static var canSelfUpdate: Bool {
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app", UpdateChecker.bundledCommit != nil else { return false }
        if app.path.contains("/AppTranslocation/") || app.path.hasPrefix("/Volumes/") { return false }
        return FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
            && FileManager.default.isWritableFile(atPath: app.path)
    }

    static func install(_ update: AvailableUpdate, progress: @escaping @MainActor (String) -> Void) async throws {
        guard let zipURL = update.zipURL, let sumsURL = update.checksumsURL else {
            throw UpdateError.message(String(localized: "Sürümde indirilecek dosya bulunamadı"))
        }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("komikku-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        // 1. Checksums, then the ZIP
        progress(String(localized: "Güncelleme indiriliyor…"))
        let (sumsData, sumsResponse) = try await URLSession.shared.data(from: sumsURL)
        guard (sumsResponse as? HTTPURLResponse)?.statusCode == 200,
              let sums = String(data: sumsData, encoding: .utf8) else {
            throw UpdateError.message(String(localized: "SHA256SUMS indirilemedi"))
        }
        let expected = sums.split(separator: "\n")
            .map { $0.split(separator: " ", omittingEmptySubsequences: true) }
            .first { $0.count == 2 && $0[1].hasSuffix(zipURL.lastPathComponent) }
            .map { String($0[0]).lowercased() }
        guard let expected else {
            throw UpdateError.message(String(localized: "SHA256SUMS içinde ZIP'in sağlaması yok"))
        }
        let (downloaded, response) = try await URLSession.shared.download(from: zipURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.message(String(localized: "Güncelleme indirilemedi"))
        }
        let zip = work.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: downloaded, to: zip)

        // 2. Integrity
        progress(String(localized: "Doğrulanıyor…"))
        let actual = try await Task.detached { () throws -> String in
            let handle = try FileHandle(forReadingFrom: zip)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
        guard actual == expected else {
            AppLog.write("update: checksum mismatch \(actual) != \(expected)")
            throw UpdateError.message(String(localized: "İndirilen dosyanın sağlaması tutmuyor; güncelleme iptal edildi"))
        }

        // 3. Unpack and check the new bundle
        try await run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        // Mekurimac.app (or Komikku.app in releases made before the rename)
        guard let newApp = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.message(String(localized: "İndirilen uygulama tanınmadı"))
        }
        guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError.message(String(localized: "İndirilen uygulama tanınmadı"))
        }
        let newCommit = info["KomikkuCommit"] as? String ?? ""
        guard !newCommit.isEmpty, newCommit.hasPrefix(update.commit) || update.commit.hasPrefix(newCommit) else {
            throw UpdateError.message(String(localized: "İndirilen sürüm beklenen sürüm değil"))
        }
        try await run("/usr/bin/codesign", ["--verify", "--deep", newApp.path])

        // 4. Swap after quitting, then start the new version
        progress(String(localized: "Yeniden başlatılıyor…"))
        let current = Bundle.main.bundleURL
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        old="$1.old-$$"
        if mv "$1" "$old"; then
            if /usr/bin/ditto "$2" "$1"; then rm -rf "$old" "$3"; else rm -rf "$1"; mv "$old" "$1"; fi
        fi
        /usr/bin/open "$1"
        """
        let swapper = Process()
        swapper.executableURL = URL(fileURLWithPath: "/bin/sh")
        swapper.arguments = ["-c", script, "komikku-update", current.path, newApp.path, work.path]
        try swapper.run()
        AppLog.write("update: installing \(newCommit.prefix(8)) into \(current.path)")
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                AppLog.write("update: \(tool) failed: \(output)")
                throw UpdateError.message(String(localized: "Güncelleme doğrulanamadı (\(URL(fileURLWithPath: tool).lastPathComponent))"))
            }
        }.value
    }
}

extension AppModel {
    func installUpdate() {
        guard let update = availableUpdate else { return }
        guard AppUpdater.canSelfUpdate, update.zipURL != nil else {
            NSWorkspace.shared.open(update.pageURL)
            return
        }
        Task {
            do {
                try await AppUpdater.install(update) { [weak self] message in self?.updateProgress = message }
            } catch {
                updateProgress = nil
                AppLog.write("update: failed: \(error.localizedDescription)")
                report(error)
            }
        }
    }
}
