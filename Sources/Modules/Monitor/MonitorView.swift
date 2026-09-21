import SwiftUI

struct MonitorModule: DockModule {
    let id = "monitor"
    let title = "Monitor"
    let systemImage = "gauge.with.dots.needle.50percent"
    func makeView() -> some View { MonitorView() }
}

struct MonitorView: View {
    @StateObject private var stats = SystemStatsService()

    var body: some View {
        List {
            GaugeRow(title: "CPU", value: stats.snapshot.cpuUsage,
                     detail: String(format: "%.0f%%", stats.snapshot.cpuUsage * 100))
            GaugeRow(title: "Memory",
                     value: ratio(stats.snapshot.memoryUsed, stats.snapshot.memoryTotal),
                     detail: "\(fmtBytes(stats.snapshot.memoryUsed)) / \(fmtBytes(stats.snapshot.memoryTotal))")
            GaugeRow(title: "Disk",
                     value: ratio(stats.snapshot.diskUsed, stats.snapshot.diskTotal),
                     detail: "\(fmtBytes(stats.snapshot.diskTotal - stats.snapshot.diskUsed)) free")
            LabeledContent("Network ↓",
                           value: "\(fmtBytes(UInt64(max(0, stats.snapshot.netBytesInPerSec))))/s")
            LabeledContent("Network ↑",
                           value: "\(fmtBytes(UInt64(max(0, stats.snapshot.netBytesOutPerSec))))/s")
        }
        .onAppear { stats.start() }
        .onDisappear { stats.stop() }
    }

    private func ratio(_ part: UInt64, _ total: UInt64) -> Double {
        total == 0 ? 0 : Double(part) / Double(total)
    }

    private func fmtBytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary)
    }
}

private struct GaugeRow: View {
    let title: String
    let value: Double
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(value, 0), 1))
        }
    }
}
