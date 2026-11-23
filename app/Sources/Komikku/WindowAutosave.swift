// SPDX-License-Identifier: GPL-3.0-or-later
//
// Remembers a window's size and position (AppKit frame autosave).

import AppKit
import SwiftUI

struct WindowAutosave: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = AutosaveView()
        view.name = name
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class AutosaveView: NSView {
        var name = ""
        private var applied = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !applied else { return }
            applied = true
            // Restores the saved frame (if any) and saves future changes
            window.setFrameAutosaveName(name)
        }
    }
}
