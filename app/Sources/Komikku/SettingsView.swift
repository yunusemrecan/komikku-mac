// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

@MainActor
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("Genel", systemImage: "gearshape") }
            ReaderSettings()
                .tabItem { Label("Okuyucu", systemImage: "book") }
            LanguageSettings()
                .tabItem { Label("Diller", systemImage: "character.bubble") }
            ServersSettings()
                .tabItem { Label("Sunucular", systemImage: "server.rack") }
            ShortcutsSettings()
                .tabItem { Label("Kısayollar", systemImage: "link") }
            AboutSettings()
                .tabItem { Label("Hakkında", systemImage: "info.circle") }
        }
        .frame(width: 600, height: 560)
    }
}

@MainActor
struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ReaderPreferences.dockBadgeKey) private var dockBadge = true
    @AppStorage(UpdateChecker.enabledKey) private var checkUpdates = true
    @AppStorage(SpotlightIndex.enabledKey) private var spotlight = true

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
            Section("Kütüphane") {
                Toggle("Açılışta kütüphaneyi güncelle", isOn: boolBinding("update-at-startup"))
                Toggle("Yeni bölümleri otomatik indir", isOn: boolBinding("new-chapters-auto-download"))
                Toggle("Dock simgesinde okunmamış bölüm sayısını göster", isOn: $dockBadge)
                    .onChange(of: dockBadge) { _, _ in model.updateDockBadge() }
                Toggle("Kütüphaneyi Spotlight'ta göster", isOn: $spotlight)
                    .onChange(of: spotlight) { _, _ in SpotlightIndex.update(with: model.library) }
                Toggle("Yeni Komikku sürümlerini denetle", isOn: $checkUpdates)
                Toggle("Masaüstü bildirimleri", isOn: Binding(
                    get: { model.settings["desktop-notifications"] as? Bool ?? false },
                    set: { value in Task { @MainActor in await model.setDesktopNotifications(value) } }
                ))
            }

            StorageSection()

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

@MainActor
struct StorageSection: View {
    @Environment(AppModel.self) private var model
    @State private var bytes: Int64?
    @State private var clearing = false

    var body: some View {
        Section("Depolama") {
            LabeledContent("Önbellek") {
                HStack {
                    if let bytes {
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                            .monospacedDigit()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Button("Önbelleği Temizle") {
                        Task { @MainActor in await clear() }
                    }
                    .disabled(clearing)
                }
            }
            Toggle("Uygulama kapanırken önbelleği temizle", isOn: Binding(
                get: { model.settings["clear-cached-data-on-app-close"] as? Bool ?? false },
                set: { value in Task { @MainActor in await model.setSetting("clear-cached-data-on-app-close", value) } }
            ))
            Text("Önbellek: kütüphanede olmayan mangaların okunan sayfaları ve kapak/logo görselleri. Kütüphanedeki indirilmiş bölümler silinmez.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await refresh() }
    }

    private func refresh() async {
        if let info = try? await model.backend.callRaw("cache.info") as? [String: Any] {
            bytes = Int64((info["chapters_bytes"] as? Int ?? 0) + (info["images_bytes"] as? Int ?? 0))
        }
    }

    private func clear() async {
        clearing = true
        defer { clearing = false }
        _ = try? await model.backend.callRaw("cache.clear")
        await refresh()
        model.showToast("Önbellek temizlendi")
    }
}

@MainActor
struct ShortcutsSettings: View {
    var body: some View {
        Form {
            Section {
                ForEach(URLAction.examples, id: \.url) { example in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(example.url).font(.body.monospaced()).textSelection(.enabled)
                            Text(example.label).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(example.url, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Kopyala")
                    }
                }
            } header: {
                Text("komikku:// bağlantıları")
            } footer: {
                Text("Kısayollar uygulamasında yeni bir kısayol oluştur, \"URL'leri Aç\" eylemini ekle ve bu bağlantılardan birini yapıştır. Kısayola bir tuş kombinasyonu atayabilir, Siri'ye söyleyebilir ya da menü çubuğundan çalıştırabilirsin. Terminal'den de çalışır: open \"komikku://continue\"")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
