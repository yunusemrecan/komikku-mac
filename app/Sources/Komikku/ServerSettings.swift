// SPDX-License-Identifier: GPL-3.0-or-later
//
// Server settings (Settings > Sunucular) and search filters, mirroring upstream's
// Preferences > Servers pages and Explorer filter menu.

import AppKit
import SwiftUI

// MARK: - JSON values (filters/params mix bools, strings and string lists)

enum JSONValue: Codable, Hashable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    /// Value for JSONSerialization (sending back to the backend).
    var any: Any {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n.truncatingRemainder(dividingBy: 1) == 0 ? Int(n) as Any : n
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .null: return NSNull()
        }
    }

    var boolValue: Bool { if case .bool(let b) = self { return b }; return false }
    var stringValue: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return ""
        }
    }
    var arrayValue: [JSONValue] { if case .array(let a) = self { return a }; return [] }
}

struct FilterOption: Codable, Hashable {
    let key: JSONValue
    let name: String
    let `default`: Bool?
}

/// A server search filter or setting parameter (upstream's `filters` / `params` entries).
struct ServerFilter: Codable, Hashable, Identifiable {
    let key: String
    let type: String
    let name: String
    let description: String?
    let valueType: String?
    let `default`: JSONValue?
    let options: [FilterOption]?

    var id: String { key }
}

struct ServerFiltersInfo: Codable {
    let filters: [ServerFilter]
    let values: [String: JSONValue]
}

struct ServerLanguageState: Codable, Hashable {
    let lang: String
    var enabled: Bool
}

struct ServerCatalogEntry: Codable, Identifiable, Hashable {
    let mainId: String
    let name: String
    var enabled: Bool
    let isNsfw: Bool
    let hasLogin: Bool
    let needsAddress: Bool
    var username: String?
    var address: String?
    let params: [ServerFilter]
    let settingsFilters: [ServerFilter]
    var paramValues: [String: JSONValue]
    var languages: [ServerLanguageState]

    var id: String { mainId }
    var hasSettings: Bool { hasLogin || !params.isEmpty || !settingsFilters.isEmpty }
}

// MARK: - Filter form

@MainActor
struct FilterFields: View {
    let filters: [ServerFilter]
    @Binding var values: [String: JSONValue]

    var body: some View {
        ForEach(filters) { filter in
            field(filter)
        }
    }

    @ViewBuilder
    private func field(_ filter: ServerFilter) -> some View {
        switch (filter.type, filter.valueType) {
        case ("checkbox", _):
            Toggle(isOn: Binding(
                get: { values[filter.key]?.boolValue ?? filter.default?.boolValue ?? false },
                set: { values[filter.key] = .bool($0) }
            )) {
                label(filter)
            }

        case ("select", "multiple"):
            Section {
                ForEach(filter.options ?? [], id: \.key) { option in
                    Toggle(option.name, isOn: Binding(
                        get: { (values[filter.key]?.arrayValue ?? []).contains(option.key) },
                        set: { on in
                            var selected = values[filter.key]?.arrayValue ?? []
                            selected.removeAll { $0 == option.key }
                            if on { selected.append(option.key) }
                            values[filter.key] = .array(selected)
                        }
                    ))
                }
            } header: {
                label(filter)
            }

        case ("select", _):
            Picker(selection: Binding(
                get: { values[filter.key] ?? filter.default ?? .null },
                set: { values[filter.key] = $0 }
            )) {
                ForEach(filter.options ?? [], id: \.key) { option in
                    Text(option.name).tag(option.key)
                }
            } label: {
                label(filter)
            }

        default:  // "entry"
            TextField(text: Binding(
                get: { values[filter.key]?.stringValue ?? filter.default?.stringValue ?? "" },
                set: { values[filter.key] = .string($0) }
            )) {
                label(filter)
            }
        }
    }

    private func label(_ filter: ServerFilter) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(filter.name)
            if let description = filter.description, !description.isEmpty, description != filter.name {
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Settings tab

@MainActor
struct ServersSettings: View {
    @Environment(AppModel.self) private var model
    @State private var catalog: [ServerCatalogEntry] = []
    @State private var filter = ""
    @State private var editing: ServerCatalogEntry?
    @State private var loading = true

    private var shown: [ServerCatalogEntry] {
        catalog.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Sunucu ara", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            List {
                ForEach(shown) { entry in
                    row(entry)
                }
            }
            .overlay { if loading { ProgressView() } }
            Text("Kapatılan sunucular sunucu listelerinde ve genel aramada görünmez.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .task { await reload() }
        .sheet(item: $editing) { entry in
            ServerSettingsSheet(entry: entry) {
                Task { @MainActor in await reload() }
            }
            .environment(model)
        }
    }

    private func row(_ entry: ServerCatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(isOn: Binding(
                    get: { entry.enabled },
                    set: { value in Task { @MainActor in await toggle(entry, value) } }
                )) {
                    HStack(spacing: 6) {
                        Text(entry.name)
                        if entry.isNsfw {
                            Text("18+").font(.caption2.bold()).foregroundStyle(.red)
                        }
                        if let username = entry.username {
                            Label(username, systemImage: "person.crop.circle.badge.checkmark")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if entry.hasSettings {
                    Button {
                        editing = entry
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.borderless)
                    .help("Sunucu ayarları")
                    .accessibilityLabel("Sunucu ayarları")
                }
            }
            if entry.enabled && entry.languages.count > 1 {
                FlowLanguages(entry: entry) { lang, on in
                    Task { @MainActor in await toggleLang(entry, lang, on) }
                }
                .padding(.leading, 20)
            }
        }
        .padding(.vertical, 2)
    }

    private func reload() async {
        do {
            catalog = try await model.backend.call("servers.catalog")
        } catch {
            model.report(error)
        }
        loading = false
    }

    private func toggle(_ entry: ServerCatalogEntry, _ enabled: Bool) async {
        _ = try? await model.backend.callRaw("server.toggle", ["main_id": entry.mainId, "enabled": enabled])
        if let i = catalog.firstIndex(of: entry) { catalog[i].enabled = enabled }
        await model.reloadServers()
    }

    private func toggleLang(_ entry: ServerCatalogEntry, _ lang: String, _ enabled: Bool) async {
        _ = try? await model.backend.callRaw("server.toggle_lang", ["main_id": entry.mainId, "lang": lang, "enabled": enabled])
        if let i = catalog.firstIndex(of: entry), let j = catalog[i].languages.firstIndex(where: { $0.lang == lang }) {
            catalog[i].languages[j].enabled = enabled
        }
        await model.reloadServers()
    }
}

@MainActor
private struct FlowLanguages: View {
    @Environment(AppModel.self) private var model
    let entry: ServerCatalogEntry
    let onToggle: (String, Bool) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 2) {
            ForEach(entry.languages, id: \.lang) { language in
                Toggle(model.languages[language.lang] ?? flag(for: language.lang), isOn: Binding(
                    get: { language.enabled },
                    set: { onToggle(language.lang, $0) }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
            }
        }
    }
}

// MARK: - Per-server sheet

@MainActor
struct ServerSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: ServerCatalogEntry
    var changed: () -> Void

    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var values: [String: JSONValue] = [:]
    @State private var loggingIn = false
    @State private var loginMessage: String?
    @State private var loggedInAs: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if entry.hasLogin {
                    Section("Hesap") {
                        if let loggedInAs {
                            LabeledContent("Giriş yapıldı", value: loggedInAs)
                            if let address = entry.address {
                                LabeledContent("Adres", value: address)
                            }
                            Button("Çıkış Yap", role: .destructive) {
                                Task { @MainActor in await logout() }
                            }
                        } else {
                            if entry.needsAddress {
                                TextField("Adres", text: $address, prompt: Text("https://sunucu.ornek:25600"))
                            }
                            TextField("Kullanıcı adı", text: $username)
                            SecureField("Parola", text: $password)
                            HStack {
                                Button("Giriş Yap") {
                                    Task { @MainActor in await login() }
                                }
                                .disabled(username.isEmpty || password.isEmpty || (entry.needsAddress && address.isEmpty) || loggingIn)
                                if loggingIn { ProgressView().controlSize(.small) }
                                if let loginMessage {
                                    Text(loginMessage).foregroundStyle(.red).font(.callout)
                                }
                            }
                            Text("Parola macOS Anahtar Zinciri'nde saklanır.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !entry.params.isEmpty || !entry.settingsFilters.isEmpty {
                    Section("Ayarlar") {
                        FilterFields(filters: entry.params + entry.settingsFilters, values: $values)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Kapat") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if !entry.params.isEmpty || !entry.settingsFilters.isEmpty {
                    Button("Kaydet") {
                        Task { @MainActor in await saveParams() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .frame(width: 460, height: 480)
        .navigationTitle(entry.name)
        .onAppear {
            values = entry.paramValues
            loggedInAs = entry.username
            address = entry.address ?? ""
        }
    }

    private func login() async {
        loggingIn = true
        loginMessage = nil
        defer { loggingIn = false }
        var params: [String: Any] = ["main_id": entry.mainId, "username": username, "password": password]
        if entry.needsAddress { params["address"] = address }
        do {
            _ = try await model.backend.callRaw("server.login", params)
            loggedInAs = username
            password = ""
            changed()
            await model.reloadServers()
        } catch {
            loginMessage = error.localizedDescription
        }
    }

    private func logout() async {
        _ = try? await model.backend.callRaw("server.logout", ["main_id": entry.mainId])
        loggedInAs = nil
        changed()
    }

    private func saveParams() async {
        let payload = values.mapValues(\.any)
        do {
            _ = try await model.backend.callRaw("server.set_params", ["main_id": entry.mainId, "values": payload])
            changed()
            dismiss()
        } catch {
            model.report(error)
        }
    }
}

// MARK: - Filters popover for browsing a server

@MainActor
struct ServerFiltersPopover: View {
    let filters: [ServerFilter]
    @Binding var values: [String: JSONValue]
    let defaults: [String: JSONValue]
    var apply: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                FilterFields(filters: filters, values: $values)
            }
            .formStyle(.grouped)
            HStack {
                Button("Sıfırla") {
                    values = defaults
                    apply()
                }
                Spacer()
                Button("Uygula") { apply() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(width: 380, height: 460)
    }
}
