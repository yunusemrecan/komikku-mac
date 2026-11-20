// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

@MainActor
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("Genel", systemImage: "gearshape") }
            LanguageSettings()
                .tabItem { Label("Diller", systemImage: "character.bubble") }
            AboutSettings()
                .tabItem { Label("Hakkında", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 420)
    }
}

@MainActor
struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ReaderPreferences.separateWindowKey) private var readerInSeparateWindow = false
    @AppStorage(ReaderPreferences.coverAloneKey) private var coverAlone = true

    private func boolBinding(_ key: String, reloadServers: Bool = false) -> Binding<Bool> {
        Binding(
            get: { model.settings[key] as? Bool ?? false },
            set: { value in
                Task { @MainActor in
                    await model.setSetting(key, value)
                    if reloadServers { await model.reloadServers() }
                }
            }
        )
    }

    var body: some View {
        Form {
            Section("Okuyucu") {
                Picker("Varsayılan okuma yönü", selection: Binding(
                    get: { model.defaultReadingMode },
                    set: { mode in Task { @MainActor in await model.setSetting("reading-mode", mode.rawValue) } }
                )) {
                    ForEach(ReadingMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Webtoon'ları otomatik algıla", isOn: boolBinding("long-strip-detection"))
                Toggle("Okuyucuyu ayrı pencerede aç", isOn: $readerInSeparateWindow)
                Toggle("Çift sayfa görünümü (varsayılan)", isOn: boolBinding("double-page"))
                Toggle("Çift sayfada kapak sayfasını tek göster", isOn: $coverAlone)
            }

            Section("Kütüphane") {
                Toggle("Açılışta kütüphaneyi güncelle", isOn: boolBinding("update-at-startup"))
            }

            Section("İçerik") {
                Toggle("Yetişkin (NSFW) içerikli sunucuları göster", isOn: boolBinding("nsfw-content", reloadServers: true))
                Toggle("Yalnızca yetişkin içerikli sunucuları da göster", isOn: boolBinding("nsfw-only-content", reloadServers: true))
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
struct LanguageSettings: View {
    @Environment(AppModel.self) private var model

    private var sortedLanguages: [(code: String, name: String)] {
        model.languages.map { ($0.key, $0.value) }.sorted { $0.name < $1.name }
    }

    var body: some View {
        Form {
            Section {
                ForEach(sortedLanguages, id: \.code) { language in
                    Toggle(language.name, isOn: Binding(
                        get: { model.serversLanguages.contains(language.code) },
                        set: { enabled in
                            var languages = model.serversLanguages.filter { $0 != language.code }
                            if enabled { languages.append(language.code) }
                            Task { @MainActor in
                                await model.setSetting("servers-languages", languages)
                                await model.reloadServers()
                            }
                        }
                    ))
                }
            } header: {
                Text("Sunucu dilleri")
            } footer: {
                Text("Hiçbiri seçili değilse tüm dillerdeki sunucular gösterilir.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
struct AboutSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Komikku for macOS").font(.title2.bold())
            Text("Valéry Febvre'nin Komikku uygulamasının macOS arayüzü.\nSunucular ve veri katmanı upstream'den olduğu gibi kullanılır.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let commit = model.upstreamCommit {
                Text("Upstream: \(commit)").font(.caption.monospaced())
            }
            Text("GPL-3.0-or-later").font(.caption).foregroundStyle(.secondary)
            Link("codeberg.org/valos/Komikku", destination: URL(string: "https://codeberg.org/valos/Komikku")!)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
