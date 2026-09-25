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
final class DiskAnalyzerViewModel: ObservableObject, @unchecked Sendable {
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
    @Published var volumes: [VolumeInfo] = []
    @Published var biggestFiles: [DiskNode] = []
    @Published var lastFreed: UInt64 = 0
    @Published var filesPerSec: Double = 0
    @Published var bytesPerSec: Double = 0
    /// Estimated seconds remaining — only meaningful for a "/" scan, where
    /// the expected total is volume used space.
    @Published var scanETA: TimeInterval?
    @Published var adminScanRunning = false

    private var scanTask: Task<Void, Never>?
    private var scanStarted: Date?
    private var scanTarget: String?
    private var adminProcess: Process?
    private var adminProgressTimer: Timer?

    init() { loadVolumeInfo(); loadVolumes() }

    struct VolumeInfo: Identifiable {
        let id = UUID()
        let name: String
        let path: String
        let total: UInt64
        let free: UInt64
    }

    /// Mounted local volumes for the sidebar, DaisyDisk-style.
    func loadVolumes() {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsInternalKey, .volumeIsBrowsableKey, .volumeIsRemovableKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]) ?? []
        var result: [VolumeInfo] = []
        for u in urls {
            guard let v = try? u.resourceValues(forKeys: keys) else { continue }
            result.append(VolumeInfo(
                name: v.volumeName ?? u.lastPathComponent,
                path: u.path,
                total: UInt64(v.volumeTotalCapacity ?? 0),
                free: UInt64(v.volumeAvailableCapacity ?? 0)))
        }
        volumes = result
    }

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
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.startScan(url.path) }
        }
    }

    func startScan(_ path: String) {
        beginScanUI(path)
        let scanner = DiskScanner { [weak self] p in
            Task { @MainActor in self?.updateProgress(p) }
        }
        scanTask = Task { [weak self] in
            let node = await scanner.scan(root: path)
            guard !Task.isCancelled else { return }
            self?.root = node
            self?.current = node
            self?.scanning = false
            self?.biggestFiles = scanner.topFiles()
        }
    }

    private func beginScanUI(_ path: String) {
        scanTask?.cancel()
        adminProcess?.terminate()
        adminProgressTimer?.invalidate()
        adminScanRunning = false
        scanning = true
        error = nil
        root = nil
        current = nil
        progress = ScanProgress()
        filesPerSec = 0
        bytesPerSec = 0
        scanETA = nil
        scanStarted = Date()
        scanTarget = path
    }

    private func updateProgress(_ p: ScanProgress) {
        progress = p
        guard let started = scanStarted else { return }
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed > 0.5, p.files > 0 else { return }
        filesPerSec = Double(p.files) / elapsed
        bytesPerSec = Double(p.bytes) / elapsed
        // ETA only when scanning the whole volume: expected bytes ≈ used space.
        if scanTarget == "/", bytesPerSec > 0 {
            let expected = Double(totalBytes) - Double(freeBytes)
            let remaining = expected - Double(p.bytes)
            scanETA = remaining > 0 ? remaining / bytesPerSec : 0
        }
    }

    // MARK: - Administrator scan

    /// Whole-disk scan as root via the embedded helper, so TCC-gated dirs
    /// (mail, messages, other users' files) are included. macOS shows one
    /// password prompt through osascript's administrator privileges.
    func scanRootAsAdmin() {
        guard let helper = Bundle.main.url(forResource: "MacDockScanHelper",
                                           withExtension: nil) else {
            error = "Privileged scan helper missing from the app bundle."
            return
        }
        beginScanUI("/")
        adminScanRunning = true

        let outPath = NSTemporaryDirectory()
            + "macdock-admin-scan-\(UUID().uuidString).json"
        let progressPath = outPath + ".progress"
        let shellCmd = "\(quoted(helper.path)) / \(quoted(outPath))"
        let source = "do shell script \"\(shellCmd)\" with administrator privileges"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        adminProcess = proc

        adminProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.pollAdminProgress(progressPath) }
        }

        Task.detached { [weak self] in
            do { try proc.run() } catch {
                await MainActor.run {
                    self?.finishAdminScan(outPath: outPath, progressPath: progressPath)
                    self?.error = "Couldn't start the privileged scan: \(error.localizedDescription)"
                }
                return
            }
            proc.waitUntilExit()
            await MainActor.run {
                self?.finishAdminScan(outPath: outPath, progressPath: progressPath)
            }
        }
    }

    private func pollAdminProgress(_ progressPath: String) {
        guard adminScanRunning, scanning else { return }
        guard let data = FileManager.default.contents(atPath: progressPath),
              let p = try? JSONDecoder().decode(ScanProgressFile.self, from: data)
        else { return }
        updateProgress(ScanProgress(files: p.files, bytes: p.bytes,
                                    currentPath: p.path))
    }

    private func finishAdminScan(outPath: String, progressPath: String) {
        adminProgressTimer?.invalidate()
        adminProgressTimer = nil
        adminProcess = nil
        defer { adminScanRunning = false }
        guard scanning else { return }   // user cancelled or a new scan started
        scanning = false
        guard let data = FileManager.default.contents(atPath: outPath),
              let result = try? JSONDecoder().decode(ScanFileResult.self, from: data)
        else {
            if FileManager.default.contents(atPath: progressPath) == nil {
                error = "Privileged scan didn't run (authorization declined or failed)."
            } else {
                error = "Privileged scan finished but its results couldn't be read."
            }
            return
        }
        root = DiskNode(dto: result.root)
        current = root
        biggestFiles = result.topFiles.map {
            DiskNode(path: $0.path, name: $0.name, size: $0.size,
                     isDirectory: false, restricted: false, children: nil)
        }
        try? FileManager.default.removeItem(atPath: outPath)
        try? FileManager.default.removeItem(atPath: progressPath)
    }

    private func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The node to Quick Look — resolves a selection id back to a live node.
    func nodeForQuickLook(_ id: UUID) -> URL? {
        guard let n = node(withID: id) ?? biggestFiles.first(where: { $0.id == id }) else {
            return nil
        }
        return URL(fileURLWithPath: n.path)
    }

    func cancelScan() {
        scanTask?.cancel()
        // osascript dies with the process; a root helper already running may
        // finish in the background — its temp output is ignored either way.
        adminProcess?.terminate()
        adminProgressTimer?.invalidate()
        adminScanRunning = false
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

    /// collecting: items sit in the bar awaiting the Delete button.
    /// emptying: truck animation running, commits to Trash when it ends.
    /// restocking: undo animation running, nothing is deleted.
    enum CollectorPhase { case collecting, emptying, restocking }

    @Published var staged: [DiskNode] = []
    @Published var collectorPhase: CollectorPhase = .collecting

    var stagedBytes: UInt64 { staged.reduce(0) { $0 + $1.size } }

    func stage(_ node: DiskNode) {
        guard collectorPhase == .collecting else { return }
        guard !staged.contains(where: { $0.id == node.id }) else { return }
        withAnimation(.spring(response: 0.3)) { staged.append(node) }
    }

    func unstage(_ node: DiskNode) {
        withAnimation(.spring(response: 0.3)) {
            staged.removeAll { $0.id == node.id }
        }
    }

    func isStaged(_ node: DiskNode) -> Bool { staged.contains { $0.id == node.id } }

    /// Resolve a dropped drag payload back to a live node — children of the
    /// current dir or entries in the biggest-files list.
    func node(withID id: UUID) -> DiskNode? {
        (current?.children ?? []).first { $0.id == id }
            ?? biggestFiles.first { $0.id == id }
    }

    /// Garbage-truck run: chips tip into the bin, then everything is trashed.
    func requestCommit() {
        guard collectorPhase == .collecting, !staged.isEmpty else { return }
        collectorPhase = .emptying
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1400))
            guard let self, !Task.isCancelled else { return }
            let doomed = self.staged
            self.staged = []
            self.collectorPhase = .collecting
            var freed: UInt64 = 0
            for node in doomed {
                freed += node.size
                self.trash(node)
            }
            self.lastFreed = freed
            self.biggestFiles.removeAll { f in doomed.contains { $0.id == f.id } }
            self.loadVolumeInfo()
            self.refreshTrashSize()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.lastFreed = 0
            }
        }
    }

    /// Restock run: chips fly back up into the stack, nothing is deleted.
    func requestRestore() {
        guard collectorPhase == .collecting, !staged.isEmpty else { return }
        collectorPhase = .restocking
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, !Task.isCancelled else { return }
            self.staged = []
            self.collectorPhase = .collecting
        }
    }

    // MARK: - Empty Trash

    /// Bytes currently sitting in ~/.Trash (for the post-delete hint).
    @Published var trashBytes: UInt64 = 0
    @Published var emptyingTrash = false

    func refreshTrashSize() {
        let trash = NSHomeDirectory() + "/.Trash"
        Task.detached { [weak self] in
            let size = await Self.dirSize(trash) ?? 0
            await MainActor.run { self?.trashBytes = size }
        }
    }

    /// Empties ~/.Trash: direct removal first, Finder's `empty trash` as the
    /// fallback for macl-protected items — same effect without Finder UI.
    func emptyTrash() {
        guard !emptyingTrash else { return }
        emptyingTrash = true
        Task.detached { [weak self] in
            let trash = NSHomeDirectory() + "/.Trash"
            var failed: String?
            // Prefer direct removal; items trashed by other apps can carry a
            // com.apple.macl data ACL that even Full Disk Access can't clear,
            // so fall back to Finder's own `empty trash`, which always works.
            if let items = try? FileManager.default.contentsOfDirectory(atPath: trash),
               items.allSatisfy({
                   (try? FileManager.default.removeItem(
                       atPath: trash + "/" + $0)) != nil
               }) {
                // emptied directly
            } else {
                let src = "tell application \"Finder\" to empty trash"
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                proc.arguments = ["-e", src]
                if (try? proc.run()) != nil {
                    proc.waitUntilExit()
                    if proc.terminationStatus != 0 {
                        failed = "Couldn't empty the Trash — grant Full Disk Access "
                            + "in System Settings → Privacy & Security."
                    }
                } else {
                    failed = "Couldn't empty the Trash — grant Full Disk Access "
                        + "in System Settings → Privacy & Security."
                }
            }
            await MainActor.run {
                self?.emptyingTrash = false
                if let failed {
                    self?.error = failed
                } else {
                    self?.trashBytes = 0
                    self?.lastFreed = 0
                }
                self?.loadVolumeInfo()
                self?.loadSpots()
                self?.refreshTrashSize()
            }
        }
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
            if let msg = vm.error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                    Text(msg).font(.caption2).lineLimit(2)
                    Spacer()
                    Button { vm.error = nil } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(Color.orange.opacity(0.12))
            }
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
            HStack(spacing: 14) {
                scanIcon("house", tip: "Scan Home") { vm.scanHome() }
                scanIcon("internaldrive", tip: "Scan Macintosh HD") { vm.scanRoot() }
                scanIcon("folder.badge.plus", tip: "Scan a folder…") { vm.pickFolder() }
            }

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

    private func scanIcon(_ symbol: String, tip: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(.accentTeal)
        .help(tip)
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
            Text(vm.adminScanRunning
                 ? "Scanning as administrator… \(vm.progress.files) items"
                 : "Scanning… \(vm.progress.files) items")
                .font(.caption)
            if vm.bytesPerSec > 0 {
                Text("\(scanRateString(vm.bytesPerSec)) · \(Int(vm.filesPerSec)) items/s"
                     + (vm.scanETA.map { " · ~\(scanETAString($0)) left" } ?? ""))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
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
