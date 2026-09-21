import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Well-known locations where space hides that macOS's own storage UI
/// doesn't surface — caches, developer junk, backups, snapshots.
struct KnownSpot: Identifiable {
    let id = UUID()
    let label: String
    let path: String
    var size: UInt64?
    var restricted = false
}

@MainActor
final class DiskAnalyzerViewModel: ObservableObject {
    @Published var scanning = false
    @Published var progress = ScanProgress()
    @Published var root: DiskNode?
    @Published var current: DiskNode?
    @Published var spots: [KnownSpot] = []
    @Published var snapshots: [String] = []
    @Published var purgeableBytes: UInt64 = 0
    @Published var freeBytes: UInt64 = 0
    @Published var totalBytes: UInt64 = 0
    @Published var error: String?

    private var scanTask: Task<Void, Never>?

    init() { loadVolumeInfo() }

    func loadVolumeInfo() {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        if let v = try? url.resourceValues(forKeys: keys) {
            totalBytes = UInt64(v.volumeTotalCapacity ?? 0)
            freeBytes = UInt64(v.volumeAvailableCapacity ?? 0)
            let important = UInt64(v.volumeAvailableCapacityForImportantUsage ?? 0)
            purgeableBytes = important > freeBytes ? important - freeBytes : 0
        }
    }

    func scanHome() { startScan(NSHomeDirectory()) }
    func scanRoot() { startScan("/") }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.startScan(url.path) }
        }
    }

    func startScan(_ path: String) {
        scanTask?.cancel()
        scanning = true
        error = nil
        root = nil
        current = nil
        let scanner = DiskScanner { [weak self] p in
            Task { @MainActor in self?.progress = p }
        }
        scanTask = Task { [weak self] in
            let node = await scanner.scan(root: path)
            guard !Task.isCancelled else { return }
            self?.root = node
            self?.current = node
            self?.scanning = false
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanning = false
    }

    func drill(_ node: DiskNode) { current = node }

    func drillUp() {
        guard let current, let root, current.id != root.id else { return }
        self.current = findParent(of: current, in: root) ?? root
    }

    private func findParent(of node: DiskNode, in parent: DiskNode) -> DiskNode? {
        if parent.children?.contains(where: { $0.id == node.id }) == true { return parent }
        for child in parent.children ?? [] {
            if let found = findParent(of: node, in: child) { return found }
        }
        return nil
    }

    func loadSpots() {
        let home = NSHomeDirectory()
        spots = [
            KnownSpot(label: "Xcode DerivedData", path: "\(home)/Library/Developer/Xcode/DerivedData"),
            KnownSpot(label: "iOS Device Backups", path: "\(home)/Library/Application Support/MobileSync/Backup"),
            KnownSpot(label: "iOS Simulators", path: "\(home)/Library/Developer/CoreSimulator"),
            KnownSpot(label: "Caches", path: "\(home)/Library/Caches"),
            KnownSpot(label: "Logs", path: "\(home)/Library/Logs"),
            KnownSpot(label: "Containers", path: "\(home)/Library/Containers"),
            KnownSpot(label: "Trash", path: "\(home)/.Trash"),
            KnownSpot(label: "System caches (/var/folders)", path: "/private/var/folders"),
            KnownSpot(label: "Sleep image & swap (/var/vm)", path: "/private/var/vm"),
        ]
        let paths = spots.map(\.path)
        Task.detached { [weak self] in
            for (i, path) in paths.enumerated() {
                let size = await Self.dirSize(path)
                await MainActor.run {
                    if let size { self?.spots[i].size = size }
                    else { self?.spots[i].restricted = true }
                }
            }
        }
        loadSnapshots()
    }

    /// Shallow total-size walk for a single directory (no tree kept).
    private nonisolated static func dirSize(_ path: String) async -> UInt64? {
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        let probe = DiskScanner { _ in }
        // scanDir produces a full tree; cheap enough for these small spots.
        let node = await probe.scan(root: path)
        return node.restricted && node.size == 0 ? nil : node.size
    }

    private func loadSnapshots() {
        Task.detached { [weak self] in
            let out = Self.runProcess("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
            let names = out
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("com.apple.TimeMachine") }
            await MainActor.run { self?.snapshots = names }
        }
    }

    private nonisolated static func runProcess(_ path: String, _ args: [String]) -> String {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func reveal(_ node: DiskNode) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
    }

    func revealPath(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func trash(_ node: DiskNode) {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: node.path),
                                              resultingItemURL: nil)
            refreshAfterDelete(node)
        } catch {
            self.error = "Couldn't move to Trash: \(error.localizedDescription)"
        }
    }

    // MARK: - Staged delete (DaisyDisk-style collector)

    /// Seconds the user has to change their mind before staged items are trashed.
    static let deleteCooldown: TimeInterval = 10

    @Published var staged: [DiskNode] = []
    @Published var deleteCountdown: TimeInterval = 0
    private var deleteTask: Task<Void, Never>?

    var stagedBytes: UInt64 { staged.reduce(0) { $0 + $1.size } }

    func stage(_ node: DiskNode) {
        guard !staged.contains(where: { $0.id == node.id }) else { return }
        staged.append(node)
        deleteCountdown = Self.deleteCooldown
        scheduleCommit()
    }

    func unstage(_ node: DiskNode) {
        staged.removeAll { $0.id == node.id }
        if staged.isEmpty { cancelStaged() }
    }

    func cancelStaged() {
        deleteTask?.cancel()
        staged = []
        deleteCountdown = 0
    }

    func isStaged(_ node: DiskNode) -> Bool { staged.contains { $0.id == node.id } }

    /// Resolve a dropped drag payload back to a live child of the current dir.
    func node(withID id: UUID) -> DiskNode? {
        (current?.children ?? []).first { $0.id == id }
    }

    private func scheduleCommit() {
        deleteTask?.cancel()
        deleteTask = Task { [weak self] in
            while let self, self.deleteCountdown > 0 {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
                self.deleteCountdown = max(0, self.deleteCountdown - 0.1)
            }
            if !Task.isCancelled { self?.commitStaged() }
        }
    }

    private func commitStaged() {
        let doomed = staged
        staged = []
        deleteCountdown = 0
        for node in doomed { trash(node) }
    }

    private func refreshAfterDelete(_ node: DiskNode) {
        guard var root else { return }
        removeFromTree(&root, id: node.id)
        self.root = root
        if current?.id == node.id { current = root }
    }

    private func removeFromTree(_ node: inout DiskNode, id: UUID) {
        node.children?.removeAll { $0.id == id }
        node.children?.indices.forEach { removeFromTree(&node.children![$0], id: id) }
        node.size = node.ownSize + (node.children ?? []).reduce(UInt64(0)) { $0 + $1.size }
    }
}

/// Drag payload for a scanned node — dropped on the delete collector.
struct DraggedNode: Codable, Transferable {
    let id: UUID
    let path: String
    let name: String
    let size: UInt64
    let isDirectory: Bool

    init(_ n: DiskNode) {
        id = n.id; path = n.path; name = n.name
        size = n.size; isDirectory = n.isDirectory
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

struct DiskAnalyzerView: View {
    @StateObject private var vm = DiskAnalyzerViewModel()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.vertical, 6)
            if vm.scanning {
                scanningView
            } else if let current = vm.current {
                resultsView(current)
            } else {
                idleView
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Disk").font(.headline)
                    Text("\(fmt(vm.freeBytes)) free of \(fmt(vm.totalBytes))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if vm.purgeableBytes > 0 {
                    Text("\(fmt(vm.purgeableBytes)) purgeable")
                        .font(.caption).foregroundStyle(.orange)
                        .help("Space macOS counts as reclaimable (snapshots, caches) — DaisyDisk-style real vs purgeable split")
                }
            }
            if !vm.snapshots.isEmpty {
                HStack {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange)
                    Text("\(vm.snapshots.count) APFS snapshot(s) — local Time Machine backups holding space")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private var idleView: some View {
        VStack(spacing: 14) {
            Spacer()
            HStack(spacing: 10) {
                Button("Scan Home") { vm.scanHome() }
                Button("Scan /") { vm.scanRoot() }
                Button("Folder…") { vm.pickFolder() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentTeal)

            Button {
                openWindow(id: "storage")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Storage Manager", systemImage: "macwindow")
                    .font(.caption)
            }
            .buttonStyle(.plain).foregroundStyle(Color.accentTeal)

            spotList
            Spacer()
        }
        .onAppear { vm.loadSpots() }
    }

    private var spotList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Known hiding spots")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(vm.spots) { spot in
                HStack {
                    Text(spot.label).font(.caption)
                    Spacer()
                    if spot.restricted {
                        Text("restricted").font(.caption2).foregroundStyle(.orange)
                    } else if let size = spot.size {
                        Text(fmt(size)).font(.caption).monospacedDigit()
                    } else {
                        ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                    }
                    Button { vm.reveal(DiskNode(path: spot.path, name: spot.label, size: spot.size ?? 0, isDirectory: true, restricted: false, children: nil)) }
                    label: { Image(systemName: "arrow.right.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: 260)
    }

    private var scanningView: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView()
            Text("Scanning… \(vm.progress.files) items")
                .font(.caption)
            Text(vm.progress.currentPath)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 320)
            Button("Cancel", role: .cancel) { vm.cancelScan() }
            Spacer()
        }
    }

    @ViewBuilder
    private func resultsView(_ current: DiskNode) -> some View {
        HStack {
            if current.id != vm.root?.id {
                Button { vm.drillUp() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentTeal)
            }
            Text(current.name).font(.headline).lineLimit(1)
            Spacer()
            Text(fmt(current.size)).font(.callout).monospacedDigit()
            Button("Rescan") { vm.startScan(current.path) }
                .buttonStyle(.borderless).font(.caption)
        }
        .padding(.horizontal, 12)

        let children = (current.children ?? []).filter { $0.size > 0 }
        TreemapView(nodes: Array(children.prefix(14))) { vm.drill($0) }
            .frame(height: 150)
            .padding(.horizontal, 12)
            .padding(.top, 6)

        List(children.prefix(60)) { child in
            HStack {
                Image(systemName: child.isDirectory ? "folder" : "doc")
                    .foregroundStyle(.secondary)
                Text(child.name).lineLimit(1).truncationMode(.middle)
                if child.restricted {
                    Image(systemName: "lock").font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
                Text(fmt(child.size)).font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { if child.isDirectory { vm.drill(child) } }
            .contextMenu {
                Button("Reveal in Finder") { vm.reveal(child) }
                Button("Move to Trash", role: .destructive) { vm.stage(child) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func fmt(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary)
    }
}
