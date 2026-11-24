// SPDX-License-Identifier: GPL-3.0-or-later
//
// Download manager: upstream's download queue (`downloads` table + Downloader).

import AppKit
import SwiftUI

@MainActor
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<Int>()

    private var groups: [(manga: String, mangaID: Int, items: [DownloadItem])] {
        var order: [Int] = []
        var byManga: [Int: [DownloadItem]] = [:]
        for item in model.downloads {
            let key = item.mangaId ?? -1
            if byManga[key] == nil { order.append(key) }
            byManga[key, default: []].append(item)
        }
        return order.map { id in
            let items = byManga[id] ?? []
            return (items.first?.mangaName ?? "?", id, items)
        }
    }

    var body: some View {
        Group {
            if model.downloads.isEmpty {
                ContentUnavailableView {
                    Label("İndirme kuyruğu boş", systemImage: "arrow.down.circle")
                } description: {
                    Text("Bir mangada bölümleri seçip sağ tık → İndir ile kuyruğa ekleyin.")
                }
            } else {
                List(selection: $selection) {
                    ForEach(groups, id: \.mangaID) { group in
                        Section {
                            ForEach(group.items) { item in
                                DownloadRow(item: item)
                                    .tag(item.chapterId)
                            }
                        } header: {
                            HStack {
                                Text(group.manga)
                                Spacer()
                                Text("\(group.items.count) bölüm").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .contextMenu(forSelectionType: Int.self) { ids in
                    Button("İptal Et") {
                        Task { @MainActor in await model.cancelDownloads(Array(ids)) }
                    }
                    .disabled(ids.isEmpty)
                }
                .onDeleteCommand {
                    let ids = Array(selection)
                    Task { @MainActor in await model.cancelDownloads(ids) }
                }
            }
        }
        .navigationTitle("İndirmeler")
        .navigationSubtitle(model.downloaderRunning ? String(localized: "İndiriliyor") : (model.downloads.isEmpty ? "" : String(localized: "Durduruldu")))
        .toolbar {
            ToolbarItemGroup {
                if model.downloaderRunning {
                    Button {
                        Task { @MainActor in await model.stopDownloader() }
                    } label: {
                        Label("Durdur", systemImage: "pause.circle")
                    }
                    .help("İndirmeyi durdur (kuyruk korunur)")
                } else {
                    Button {
                        Task { @MainActor in await model.startDownloader() }
                    } label: {
                        Label("Başlat", systemImage: "play.circle")
                    }
                    .disabled(model.downloads.isEmpty)
                    .help("İndirmeyi başlat (hatalılar yeniden denenir)")
                }
                Button(role: .destructive) {
                    let ids = model.downloads.map(\.chapterId)
                    Task { @MainActor in await model.cancelDownloads(ids) }
                } label: {
                    Label("Tümünü İptal Et", systemImage: "trash")
                }
                .disabled(model.downloads.isEmpty)
                .help("Kuyruğu temizle")
            }
        }
        .task { await model.reloadDownloads() }
    }
}

@MainActor
struct DownloadRow: View {
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.chapterTitle ?? "Bölüm \(item.chapterId)")
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.statusLabel)
                    if let errors = item.errors, errors > 0 {
                        Text("· \(errors) sayfa hatalı").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(item.status == "error" ? .orange : .secondary)
            }
            Spacer()
            if item.status == "downloading" || item.percent > 0 {
                ProgressView(value: min(item.percent, 100), total: 100)
                    .frame(width: 140)
                Text("%\(Int(item.percent))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }
}
