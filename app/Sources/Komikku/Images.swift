// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Small in-memory cache for decoded images, keyed by file path.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 400
    }

    func image(atPath path: String) async -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) {
            return cached
        }
        let data = await Task.detached(priority: .userInitiated) { () -> Data? in
            try? Data(contentsOf: URL(fileURLWithPath: path))
        }.value
        let loaded = data.flatMap { NSImage(data: $0) }
        if let loaded {
            cache.setObject(loaded, forKey: path as NSString)
        }
        return loaded
    }

    func remove(path: String) {
        cache.removeObject(forKey: path as NSString)
    }
}

/// Cover from a local file path, or from a remote URL fetched through the backend
/// (so the server's headers / cookies / referer are used).
@MainActor
struct CoverImage: View {
    var localPath: String?
    var remoteURL: String?
    var serverID: String?

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if failed {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .aspectRatio(180.0 / 256.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: (localPath ?? "") + (remoteURL ?? "")) {
            await load()
        }
    }

    private func load() async {
        failed = false
        if let localPath, let loaded = await ImageCache.shared.image(atPath: localPath) {
            image = loaded
            return
        }
        guard let remoteURL, let serverID else {
            failed = true
            return
        }
        do {
            let path = try await AppModel.shared.backend.callRaw(
                "server.image", ["server_id": serverID, "url": remoteURL]
            ) as? String
            if let path, let loaded = await ImageCache.shared.image(atPath: path) {
                image = loaded
            } else {
                failed = true
            }
        } catch {
            failed = true
        }
    }
}
