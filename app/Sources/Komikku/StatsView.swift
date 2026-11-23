// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reading statistics: headline numbers, chapters per day (last 30 days),
// most-read series in that period.

import Charts
import SwiftUI

struct ReadingStats: Codable {
    struct Day: Codable, Identifiable {
        let date: String
        let chapters: Int
        var id: String { date }

        var day: Date {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f.date(from: date) ?? .distantPast
        }
    }

    struct Top: Codable, Identifiable {
        let mangaId: Int
        let name: String
        let serverName: String?
        let chapters: Int
        let coverPath: String?
        var id: Int { mangaId }
    }

    let totalRead: Int
    let last7Days: Int
    let last30Days: Int
    let streakDays: Int
    let libraryCount: Int
    let daily: [Day]
    let top: [Top]
}

@MainActor
struct StatsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openRoute) private var openRoute

    @State private var stats: ReadingStats?
    @State private var selectedDay: Date?

    var body: some View {
        Group {
            if let stats {
                content(stats)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("İstatistikler")
        .navigationSubtitle("Son 30 gün")
        .toolbar {
            Button {
                Task { @MainActor in await reload() }
            } label: {
                Label("Yenile", systemImage: "arrow.clockwise")
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        do {
            stats = try await model.backend.call("stats.reading", ["days": 30])
            AppLog.write("stats: total=\(stats?.totalRead ?? -1) last7=\(stats?.last7Days ?? -1)")
        } catch {
            model.report(error)
        }
    }

    private func content(_ stats: ReadingStats) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 14) {
                    StatTile(value: stats.last7Days, label: "Son 7 günde bölüm")
                    StatTile(value: stats.last30Days, label: "Son 30 günde bölüm")
                    StatTile(value: stats.streakDays, label: stats.streakDays == 1 ? "Günlük seri (gün)" : "Ardışık okuma günü")
                    StatTile(value: stats.totalRead, label: "Toplam okunan bölüm")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Günlük okunan bölümler").font(.headline)
                    if stats.daily.allSatisfy({ $0.chapters == 0 }) {
                        Text("Son 30 günde okuma kaydı yok.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        dailyChart(stats.daily)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 10) {
                    Text("En çok okunan seriler").font(.headline)
                    if stats.top.isEmpty {
                        Text("Bu dönemde okunan seri yok.").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(stats.top.enumerated()), id: \.element.id) { rank, item in
                            topRow(rank: rank + 1, item: item, max: stats.top.first?.chapters ?? 1)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))

                Text("Bir bölüm, okunduğu gün sayılır. Toplu \"okundu\" işaretlenen bölümler yalnızca toplamda yer alır.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private func dailyChart(_ days: [ReadingStats.Day]) -> some View {
        Chart {
            ForEach(days) { day in
                BarMark(
                    x: .value("Gün", day.day, unit: .day),
                    y: .value("Bölüm", day.chapters)
                )
                .foregroundStyle(Color.accentColor.opacity(
                    selectedDay == nil || Calendar.current.isDate(day.day, inSameDayAs: selectedDay!) ? 1 : 0.4
                ))
                .cornerRadius(4)
            }
            if let selectedDay, let day = days.first(where: { Calendar.current.isDate($0.day, inSameDayAs: selectedDay) }) {
                RuleMark(x: .value("Gün", day.day, unit: .day))
                    .foregroundStyle(.secondary.opacity(0.3))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        VStack(spacing: 2) {
                            Text(day.day.formatted(.dateTime.day().month(.abbreviated)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(day.chapters) bölüm").font(.callout.bold())
                        }
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
            }
        }
        .chartXSelection(value: $selectedDay)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel()
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .frame(height: 200)
    }

    private func topRow(rank: Int, item: ReadingStats.Top, max: Int) -> some View {
        Button {
            openRoute(.manga(item.mangaId))
        } label: {
            HStack(spacing: 12) {
                Text("\(rank)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .trailing)
                CoverImage(localPath: item.coverPath)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).lineLimit(1)
                    if let server = item.serverName {
                        Text(server).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                // Proportional bar + value (text stays in text color)
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor)
                        .frame(width: max > 0 ? proxy.size.width * CGFloat(item.chapters) / CGFloat(max) : 0, height: 6)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(width: 120, height: 20)
                Text("\(item.chapters) bölüm")
                    .font(.callout.monospacedDigit())
                    .frame(width: 80, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

@MainActor
struct StatTile: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)")
                .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}
