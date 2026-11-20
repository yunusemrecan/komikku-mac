// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Opens a chapter: embedded in the main window (default) or in its own window,
/// depending on the "Okuyucuyu ayrı pencerede aç" setting.
struct OpenReaderAction {
    var perform: (ReaderTarget) -> Void

    func callAsFunction(_ target: ReaderTarget) {
        perform(target)
    }
}

struct OpenReaderKey: EnvironmentKey {
    static let defaultValue = OpenReaderAction { _ in }
}

extension EnvironmentValues {
    var openReader: OpenReaderAction {
        get { self[OpenReaderKey.self] }
        set { self[OpenReaderKey.self] = newValue }
    }
}

enum ReaderPreferences {
    static let separateWindowKey = "reader-in-separate-window"
    static let coverAloneKey = "reader-cover-alone"
}
