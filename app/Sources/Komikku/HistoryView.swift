// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reading history: last chapter read per manga and day (upstream's History page).

import AppKit
import SwiftUI

@MainActor
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openReader) private var openReader
    @Environment(\.openRoute) private var openRoute
    var searchFocusRequest: Int

    @State private var entries: [HistoryEntry] = []
    @State private var search = ""
    @State private var searchPresented = false
    @State private var loaded = false
    @State private var confirmClear = false

    private var grouped: [(date: String, entries: [HistoryEntry])] {
        let filtered = entries.filter { search.isEmpty || $0.mangaName.localizedCaseInsensitiveContains(search) }
        var order: [String] = []
        var byDate: [String: [HistoryEntry]] = [:]
        for entry in filtered {
            if byDate[entry.date] == nil { order.append(entry.date) }
            byDate[entry.date, default: []].append(entry)
        }
        return order.map { ($0, byDate[$0] ?? []) }
    }

    var body: some View {
        Group {
            if loaded && entries.isEmpty {
                ContentUnavailableView("Geçmiş boş", systemImage: "clock",
                                       description: Text("Okuduğunuz bölümler burada gün gün listelenir (son 90 gün)."))
            } else {
                List {
                    ForEach(grouped, id: \.date) { group in
                        Section(dayLabel(group.date)) {
                            ForEach(group.entries) { entry in
                                row(entry)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Geçmiş")
        .searchable(text: $search, isPresented: $searchPresented, placement: .toolbar, prompt: "Geçmişte ara")
        .onChange(of: searchFocusRequest) { _, _ in searchPresented = true }
        .toolbar {
            Button(role: .destructive) {
                confirmClear = true
            } label: {
                Label("Geçmişi Temizle", systemImage: "trash")
            }
            .disabled(entries.isEmpty)
            .help("Geçmişi temizle")
        }
        .confirmationDialog("Tüm okuma geçmişi silinsin mi?", isPresented: $confirmClear) {
            Button("Temizle", role: .destructive) {
                Task { @MainActor in
                    _ = try? await model.backend.callRaw("history.clear")
                    await reload()
                }
            }
        } message: {
            Text("Okundu işaretleri ve okuma ilerlemesi korunur; yalnızca son okuma tarihleri silinir.")
        }
        .task { await reload() }
    }

    private func row(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 12) {
            CoverImage(localPath: entry.coverPath)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.mangaName).font(.headline).lineLimit(1)
                Text(entry.chapterTitle).lineLimit(1)
                HStack(spacing: 6) {
                    if let time = timeLabel(entry.lastRead) { Text(time) }
                    if let server = entry.serverName { Text("· \(server)") }
                    if !entry.chapterRead, let page = entry.lastPageReadIndex {
                        Text("· Sayfa \(page + 1)")
                    } else if entry.chapterRead {
                        Text("· Okundu")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                openReader(ReaderTarget(mangaId: entry.mangaId, chapterId: entry.chapterId))
            } label: {
                Label("Devam Et", systemImage: "book")
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            openReader(ReaderTarget(mangaId: entry.mangaId, chapterId: entry.chapterId))
        }
        .contextMenu {
            Button("Okumaya Devam Et") {
                openReader(ReaderTarget(mangaId: entry.mangaId, chapterId: entry.chapterId))
            }
            Button("Mangayı Aç") { openRoute(.manga(entry.mangaId)) }
            Divider()
            Button("Bu Mangayı Geçmişten Kaldır", role: .destructive) {
                Task { @MainActor in
                    _ = try? await model.backend.callRaw("history.clear", ["manga_id": entry.mangaId])
                    await reload()
                }
            }
        }
    }

    private func reload() async {
        if let list: [HistoryEntry] = try? await model.backend.call("history.list") {
            entries = list
        }
        loaded = true
    }

    private func dayLabel(_ iso: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: iso) else { return iso }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Bugün" }
        if calendar.isDateInYesterday(date) { return "Dün" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    private func timeLabel(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: iso)
        }() ?? {
            // SQLite style "2026-11-20 09:12:33.123456+00:00"
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSxxx"
            return f.date(from: iso)
        }()
        return date?.formatted(date: .omitted, time: .shortened)
    }
}
