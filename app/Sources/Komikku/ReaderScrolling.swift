// SPDX-License-Identifier: GPL-3.0-or-later
//
// Keyboard scrolling for the reader. On macOS 14 SwiftUI's ScrollView cannot be
// scrolled by an arbitrary offset from code, so we locate the NSScrollView that
// backs it and move its clip view directly.

import AppKit
import SwiftUI

@MainActor
final class ScrollHandle {
    weak var scrollView: NSScrollView?

    private var clip: NSClipView? { scrollView?.contentView }

    var viewport: CGSize { clip?.bounds.size ?? .zero }

    /// Scrolls by a delta in "visual" terms (dy > 0 = down, dx > 0 = right).
    /// Returns false when already at the edge in that direction (nothing moved).
    @discardableResult
    func scroll(dx: CGFloat = 0, dy: CGFloat = 0, animated: Bool = true) -> Bool {
        guard let scrollView, let clip = clip, scrollView.documentView != nil else { return false }
        let visible = clip.bounds
        let document = clip.documentRect
        let flipped = clip.isFlipped

        let minX = document.minX
        let maxX = max(document.minX, document.maxX - visible.width)
        let minY = document.minY
        let maxY = max(document.minY, document.maxY - visible.height)

        let target = NSPoint(
            x: min(max(visible.origin.x + dx, minX), maxX),
            y: min(max(visible.origin.y + (flipped ? dy : -dy), minY), maxY)
        )
        if abs(target.x - visible.origin.x) < 0.5 && abs(target.y - visible.origin.y) < 0.5 {
            return false
        }
        move(to: target, animated: animated)
        return true
    }

    /// Jump to the top (or bottom) of the document, keeping the horizontal position.
    func scrollToEdge(bottom: Bool, animated: Bool = false) {
        guard let clip = clip else { return }
        let visible = clip.bounds
        let document = clip.documentRect
        let top = clip.isFlipped ? document.minY : max(document.minY, document.maxY - visible.height)
        let end = clip.isFlipped ? max(document.minY, document.maxY - visible.height) : document.minY
        move(to: NSPoint(x: visible.origin.x, y: bottom ? end : top), animated: animated)
    }

    private func move(to point: NSPoint, animated: Bool) {
        guard let scrollView, let clip = clip else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(point)
            } completionHandler: {
                scrollView.reflectScrolledClipView(clip)
            }
        } else {
            clip.setBoundsOrigin(point)
            scrollView.reflectScrolledClipView(clip)
        }
    }
}

/// Put inside a ScrollView's content: hands the backing NSScrollView to `handle`.
struct ScrollViewFinder: NSViewRepresentable {
    let handle: ScrollHandle

    func makeNSView(context: Context) -> FinderView {
        let view = FinderView()
        view.handle = handle
        return view
    }

    func updateNSView(_ view: FinderView, context: Context) {
        view.handle = handle
        view.attach()
    }

    final class FinderView: NSView {
        weak var handle: ScrollHandle?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        func attach() {
            guard let scrollView = enclosingScrollView else { return }
            MainActor.assumeIsolated {
                handle?.scrollView = scrollView
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
