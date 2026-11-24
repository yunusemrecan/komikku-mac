// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copy / save / share / drag a page, with a readable file name
// ("Manga – Chapter – p5.jpg") instead of the cache's "005" name.

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

extension ReaderModel {
    /// Human-friendly file name for a page.
    func exportName(for index: Int) -> String {
        let manga = manga?.name ?? "Manga"
        let chapter = chapter?.title ?? String(localized: "Bölüm")
        let raw = "\(manga) – \(chapter) – s\(index + 1)"
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return String(cleaned.prefix(180))
    }

    /// File extension from the image data itself (cache files have no extension).
    private static func fileExtension(forImageAt path: String) -> String {
        let url = URL(fileURLWithPath: path) as CFURL
        if let source = CGImageSourceCreateWithURL(url, nil),
           let type = CGImageSourceGetType(source) as String?,
           let ext = UTType(type)?.preferredFilenameExtension {
            return ext
        }
        return "jpg"
    }

    /// Copy of the page with a readable name in a temporary export folder.
    func exportedFile(for index: Int) -> URL? {
        guard let path = pagePaths[index] else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Komikku-export", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent(exportName(for: index))
            .appendingPathExtension(Self.fileExtension(forImageAt: path))
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: target)
            return target
        } catch {
            return nil
        }
    }

    func copyPage(_ index: Int, image: NSImage?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var objects: [NSPasteboardWriting] = []
        if let image { objects.append(image) }
        if let url = exportedFile(for: index) { objects.append(url as NSURL) }
        pasteboard.writeObjects(objects)
        AppModel.shared.showToast(String(localized: "Sayfa \(index + 1) kopyalandı"))
    }

    func savePageAs(_ index: Int) {
        guard let source = exportedFile(for: index) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.lastPathComponent
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(at: source, to: destination)
        }
    }

    func sharePage(_ index: Int) {
        guard let url = exportedFile(for: index),
              let window = NSApp.keyWindow, let view = window.contentView else { return }
        // Anchor the share menu at the mouse pointer
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: NSRect(origin: point, size: CGSize(width: 1, height: 1)), of: view, preferredEdge: .minY)
    }

    func revealPage(_ index: Int) {
        guard let url = exportedFile(for: index) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Context menu + drag source for a displayed page.
@MainActor
struct PageActions: ViewModifier {
    let model: ReaderModel
    let index: Int
    let image: NSImage?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Sayfayı Kopyala") { model.copyPage(index, image: image) }
                Button("Farklı Kaydet…") { model.savePageAs(index) }
                Button("Paylaş…") { model.sharePage(index) }
                Divider()
                Button("Finder'da Göster") { model.revealPage(index) }
            }
            .onDrag {
                guard let url = model.exportedFile(for: index) else { return NSItemProvider() }
                let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider()
                provider.suggestedName = url.deletingPathExtension().lastPathComponent
                return provider
            }
    }
}
