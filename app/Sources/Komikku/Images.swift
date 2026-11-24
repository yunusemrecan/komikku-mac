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

    /// Page image, optionally with white/uniform borders cropped (threshold 0...255).
    func image(atPath path: String, cropThreshold: Int?) async -> NSImage? {
        guard let threshold = cropThreshold else { return await image(atPath: path) }
        let key = "\(path)#crop\(threshold)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let result = await Task.detached(priority: .userInitiated) { () -> (Data, CGRect?)? in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            return (data, BordersCrop.contentRect(data: data, threshold: threshold))
        }.value
        guard let result, let full = NSImage(data: result.0) else { return nil }
        let rect = result.1
        var output = full
        if let rect, let cg = full.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let cropped = cg.cropping(to: rect) {
            output = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        }
        cache.setObject(output, forKey: key)
        return output
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
        // The fixed-ratio box decides the size; the image only fills (and is clipped to) it,
        // so a wide cover can never push the layout wider than its slot
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(180.0 / 256.0, contentMode: .fit)
            .accessibilityHidden(true)
            .overlay {
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
