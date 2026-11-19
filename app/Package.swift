// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

let package = Package(
    name: "Komikku",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Komikku",
            path: "Sources/Komikku"
        ),
    ]
)
