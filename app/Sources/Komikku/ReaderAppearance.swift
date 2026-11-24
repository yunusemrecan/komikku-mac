// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reader appearance: scaling, background, borders crop, page filters.
// Same settings keys / per-manga columns as upstream Komikku.

import AppKit
import CoreGraphics
import ImageIO
import SwiftUI

enum PageScaling: String, CaseIterable, Identifiable {
    case screen, width, height, original

    var id: String { rawValue }
    var label: String {
        switch self {
        case .screen: return String(localized: "Ekrana sığdır")
        case .width: return String(localized: "Genişliğe sığdır")
        case .height: return String(localized: "Yüksekliğe sığdır")
        case .original: return String(localized: "Orijinal boyut")
        }
    }
}

enum ReaderBackground: String, CaseIterable, Identifiable {
    case systemStyle = "system-style"
    case white, black, gray

    var id: String { rawValue }
    var label: String {
        switch self {
        case .systemStyle: return String(localized: "Sistem görünümü")
        case .white: return String(localized: "Beyaz")
        case .black: return String(localized: "Siyah")
        case .gray: return String(localized: "Gri")
        }
    }

    func color(_ scheme: ColorScheme) -> Color {
        switch self {
        case .white: return .white
        case .black: return .black
        case .gray: return Color(white: 0.5)
        case .systemStyle: return scheme == .dark ? .black : .white
        }
    }

    /// Color scheme for text/spinners drawn over the background
    func contentScheme(_ scheme: ColorScheme) -> ColorScheme {
        switch self {
        case .white: return .light
        case .black, .gray: return .dark
        case .systemStyle: return scheme
        }
    }
}

/// Upstream's FILTERS (reader/settings.py): values in percent, `<name>-state` toggles them.
struct PageFilterSpec: Identifiable {
    let key: String
    let title: String
    let range: ClosedRange<Double>
    let defaultValue: Double
    var id: String { key }

    static let all: [PageFilterSpec] = [
        PageFilterSpec(key: "brightness", title: String(localized: "Parlaklık"), range: 0...200, defaultValue: 100),
        PageFilterSpec(key: "contrast", title: String(localized: "Kontrast"), range: 0...200, defaultValue: 100),
        PageFilterSpec(key: "grayscale", title: String(localized: "Gri tonlama"), range: 0...100, defaultValue: 100),
        PageFilterSpec(key: "invert", title: String(localized: "Ters çevir (gece)"), range: 0...100, defaultValue: 100),
        PageFilterSpec(key: "sepia", title: String(localized: "Sepya"), range: 0...100, defaultValue: 0),
        PageFilterSpec(key: "saturate", title: String(localized: "Doygunluk"), range: 0...400, defaultValue: 100),
    ]
}

struct PageFilters: Equatable {
    var values: [String: Any] = [:]

    static func == (lhs: PageFilters, rhs: PageFilters) -> Bool {
        NSDictionary(dictionary: lhs.values).isEqual(to: rhs.values)
    }

    init(json: String?) {
        if let json, let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            values = object
        }
    }

    var json: String {
        let data = (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func isOn(_ key: String) -> Bool { values["\(key)-state"] as? Bool ?? false }

    func value(_ spec: PageFilterSpec) -> Double {
        (values[spec.key] as? NSNumber)?.doubleValue ?? spec.defaultValue
    }

    mutating func set(_ key: String, on: Bool) {
        values["\(key)-state"] = on
    }

    mutating func set(_ key: String, value: Double) {
        values[key] = value
    }

    func amount(_ key: String) -> Double? {
        guard isOn(key), let spec = PageFilterSpec.all.first(where: { $0.key == key }) else { return nil }
        return value(spec) / 100
    }

    var isActive: Bool { PageFilterSpec.all.contains { isOn($0.key) } }
}

extension View {
    /// Approximates upstream's CSS-like page filters with SwiftUI color effects.
    @ViewBuilder
    func pageFilters(_ filters: PageFilters) -> some View {
        if !filters.isActive {
            self
        } else {
            let invert = filters.amount("invert")
            let gray = max(filters.amount("grayscale") ?? 0, invert != nil ? 1 : 0)
            let sepia = filters.amount("sepia") ?? 0
            self
                .brightness(((filters.amount("brightness") ?? 1) - 1) * 0.5)
                .contrast(filters.amount("contrast") ?? 1)
                .saturation(filters.amount("saturate") ?? 1)
                .grayscale(min(1, gray + sepia))
                .colorMultiply(sepia > 0
                               ? Color(red: 1, green: 1 - 0.08 * sepia, blue: 1 - 0.25 * sepia)
                               : .white)
                .modifier(InvertModifier(amount: invert ?? 0))
        }
    }
}

private struct InvertModifier: ViewModifier {
    let amount: Double

    func body(content: Content) -> some View {
        if amount >= 0.5 {
            content.colorInvert()
        } else {
            content
        }
    }
}

// MARK: - Borders crop

enum BordersCrop {
    /// Bounding box of the non-border area, in pixels (top-left origin), or nil when nothing to crop.
    /// A pixel belongs to the border when its luminance is above `threshold` (0...255), like upstream.
    static func contentRect(data: Data, threshold: Int) -> CGRect? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let fullWidth = image.width
        let fullHeight = image.height
        // Work on a downscaled grayscale copy for speed
        let scale = min(1.0, 400.0 / Double(max(fullWidth, fullHeight)))
        let width = max(1, Int(Double(fullWidth) * scale))
        let height = max(1, Int(Double(fullHeight) * scale))

        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        let limit = UInt8(clamping: threshold)
        func rowIsBorder(_ y: Int) -> Bool {
            let start = y * width
            for x in 0..<width where pixels[start + x] < limit { return false }
            return true
        }
        func columnIsBorder(_ x: Int, _ top: Int, _ bottom: Int) -> Bool {
            for y in top...bottom where pixels[y * width + x] < limit { return false }
            return true
        }

        var top = 0
        while top < height - 1 && rowIsBorder(top) { top += 1 }
        var bottom = height - 1
        while bottom > top && rowIsBorder(bottom) { bottom -= 1 }
        var left = 0
        while left < width - 1 && columnIsBorder(left, top, bottom) { left += 1 }
        var right = width - 1
        while right > left && columnIsBorder(right, top, bottom) { right -= 1 }

        // Nothing meaningful to crop (or a blank page)
        if top == 0 && left == 0 && bottom == height - 1 && right == width - 1 { return nil }
        if right - left < width / 5 || bottom - top < height / 5 { return nil }

        // Map back to full resolution, with a 1px safety margin
        let inv = 1.0 / scale
        let x = max(0, (Double(left) - 1) * inv)
        let y = max(0, (Double(top) - 1) * inv)
        let w = min(Double(fullWidth) - x, (Double(right - left) + 3) * inv)
        let h = min(Double(fullHeight) - y, (Double(bottom - top) + 3) * inv)
        return CGRect(x: x, y: y, width: w, height: h).integral
    }
}

// MARK: - Reader "Görünüm" popover (per-manga settings + global filters)

@MainActor
struct ReaderAppearancePanel: View {
    let model: ReaderModel

    var body: some View {
        Form {
            Section {
                Picker("Ölçekleme", selection: Binding(get: { model.scaling }, set: { model.setScaling($0) })) {
                    ForEach(PageScaling.allCases) { Text($0.label).tag($0) }
                }
                .disabled(model.mode == .webtoon)

                HStack {
                    Text("Yakınlaştırma")
                    Spacer()
                    Button { model.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                        .buttonStyle(.borderless)
                    Text("%\(Int((model.zoom * 100).rounded()))")
                        .monospacedDigit()
                        .frame(width: 48)
                    Button { model.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                        .buttonStyle(.borderless)
                    Button("Sıfırla") { model.resetZoom() }
                        .buttonStyle(.borderless)
                        .disabled(model.zoom == 1)
                }
                .disabled(model.mode == .webtoon)

                Toggle("Yatay sayfaları yüksekliğe sığdır", isOn: Binding(
                    get: { model.landscapeZoom }, set: { model.setLandscapeZoom($0) }
                ))
                .disabled(model.mode == .webtoon || model.scaling != .screen)

                Picker("Arka plan", selection: Binding(get: { model.background }, set: { model.setBackground($0) })) {
                    ForEach(ReaderBackground.allCases) { Text($0.label).tag($0) }
                }

                Toggle("Kenar boşluklarını kırp", isOn: Binding(
                    get: { model.bordersCrop }, set: { model.setBordersCrop($0) }
                ))
                .disabled(model.mode == .webtoon)
                if model.bordersCrop && model.mode != .webtoon {
                    LabeledContent("Kırpma eşiği") {
                        Slider(value: Binding(
                            get: { Double(model.bordersCropThreshold) },
                            set: { model.setBordersCropThreshold(Int($0)) }
                        ), in: 150...250, step: 5)
                        .frame(width: 160)
                    }
                }

                Toggle("Sayfa numarasını göster", isOn: Binding(
                    get: { model.pageNumbering }, set: { model.setPageNumbering($0) }
                ))
            } header: {
                Text("Bu manga için")
            }

            Section {
                ForEach(PageFilterSpec.all) { spec in
                    filterRow(spec)
                }
            } header: {
                Text("Sayfa filtreleri (tüm mangalar)")
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .frame(maxHeight: 620)
    }

    @ViewBuilder
    private func filterRow(_ spec: PageFilterSpec) -> some View {
        Toggle(spec.title, isOn: Binding(
            get: { model.filters.isOn(spec.key) },
            set: { on in
                var filters = model.filters
                filters.set(spec.key, on: on)
                model.setFilters(filters)
            }
        ))
        if model.filters.isOn(spec.key) && spec.key != "invert" {
            Slider(value: Binding(
                get: { model.filters.value(spec) },
                set: { value in
                    var filters = model.filters
                    filters.set(spec.key, value: value.rounded())
                    model.setFilters(filters)
                }
            ), in: spec.range) {
                Text("%\(Int(model.filters.value(spec)))").monospacedDigit()
            }
        }
    }
}

// MARK: - Settings > Okuyucu (global defaults)

@MainActor
struct ReaderSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ReaderPreferences.separateWindowKey) private var readerInSeparateWindow = false
    @AppStorage(ReaderPreferences.coverAloneKey) private var coverAlone = true
    @AppStorage(AppModel.readAheadKey) private var readAhead = 2
    @AppStorage(AppModel.deleteFinishedKey) private var deleteFinished = false

    private func boolBinding(_ key: String, _ fallback: Bool = false) -> Binding<Bool> {
        Binding(
            get: { model.settings[key] as? Bool ?? fallback },
            set: { value in Task { @MainActor in await model.setSetting(key, value) } }
        )
    }

    private func stringBinding(_ key: String, _ fallback: String) -> Binding<String> {
        Binding(
            get: { model.settings[key] as? String ?? fallback },
            set: { value in Task { @MainActor in await model.setSetting(key, value) } }
        )
    }

    var body: some View {
        Form {
            Section("Varsayılanlar") {
                Picker("Okuma yönü", selection: Binding(
                    get: { model.defaultReadingMode },
                    set: { mode in Task { @MainActor in await model.setSetting("reading-mode", mode.rawValue) } }
                )) {
                    ForEach(ReadingMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Ölçekleme", selection: stringBinding("scaling", "screen")) {
                    ForEach(PageScaling.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Arka plan", selection: stringBinding("background-color", "system-style")) {
                    ForEach(ReaderBackground.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Toggle("Çift sayfa görünümü", isOn: boolBinding("double-page"))
                Toggle("Çift sayfada kapak sayfasını tek göster", isOn: $coverAlone)
                Toggle("Kenar boşluklarını kırp", isOn: boolBinding("borders-crop"))
                Toggle("Yatay sayfaları yüksekliğe sığdır", isOn: boolBinding("landscape-zoom"))
                Toggle("Sayfa numarasını göster", isOn: boolBinding("page-numbering", true))
            }
            Section("Webtoon") {
                Toggle("Webtoon'ları otomatik algıla", isOn: boolBinding("long-strip-detection"))
                LabeledContent("En fazla genişlik") {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(model.settings["clamp-size"] as? Int ?? 960) },
                            set: { value in Task { @MainActor in await model.setSetting("clamp-size", Int(value)) } }
                        ), in: 480...2400, step: 40)
                        .frame(width: 180)
                        Text("\(model.settings["clamp-size"] as? Int ?? 960) pt").monospacedDigit()
                    }
                }
            }
            Section {
                Picker("Okurken sonraki bölümleri indir", selection: $readAhead) {
                    Text("Kapalı").tag(0)
                    ForEach(1...5, id: \.self) { Text("\($0) bölüm").tag($0) }
                }
                Toggle("Bitirilen bölümün indirilmiş dosyalarını sil", isOn: $deleteFinished)
            } header: {
                Text("İndirmeler")
            } footer: {
                Text("Yalnızca kütüphanedeki mangalar için. Bir bölümün son sayfasına gelip sonrakine geçince o bölüm \"bitirilmiş\" sayılır; okundu bilgisi silinmez.")
                    .foregroundStyle(.secondary)
            }
            Section("Pencere") {
                Toggle("Okuyucuyu ayrı pencerede aç", isOn: $readerInSeparateWindow)
            }
            Text("Manga başına ayarlar okuyucudaki Görünüm panelinden değiştirilir ve bu varsayılanları geçersiz kılar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
