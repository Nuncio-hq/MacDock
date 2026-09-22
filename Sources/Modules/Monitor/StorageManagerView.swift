import SwiftUI
import AppKit

/// Full-window disk analyzer ("Storage Manager") — the menubar panel stays a
/// quick view; this is where actual cleanup work happens.
struct StorageManagerView: View {
    @StateObject private var vm = DiskAnalyzerViewModel()
    @State private var selection = Set<DiskNode.ID>()
    @State private var showBiggest = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            detail
        }
        .frame(minWidth: 840, minHeight: 520)
        .onAppear {
            vm.loadSpots()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List {
            Section("Scan") {
                sidebarButton("Home Folder", icon: "house") { vm.scanHome() }
                sidebarButton("Macintosh HD", icon: "internaldrive") { vm.scanRoot() }
                sidebarButton("Macintosh HD (administrator)", icon: "lock.shield") {
                    vm.scanRootAsAdmin()
                }
                sidebarButton("Folder…", icon: "folder.badge.plus") { vm.pickFolder() }
                if vm.root != nil {
                    sidebarButton("Biggest files", icon: "arrow.up.doc") {
                        showBiggest = true
                    }
                }
            }
            let extraVolumes = vm.volumes.filter { $0.path != "/" }
            if !extraVolumes.isEmpty {
                Section("Volumes") {
                    ForEach(extraVolumes) { vol in
                        Button {
                            showBiggest = false
                            vm.startScan(vol.path)
                        } label: {
                            HStack {
                                Image(systemName: "externaldrive")
                                    .foregroundStyle(Color.accentTeal)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(vol.name).font(.callout)
                                    Text("\(Self.fmt(vol.free)) free of \(Self.fmt(vol.total))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Scan \(vol.path)")
                    }
                }
            }
            Section("Known hiding spots") {
                ForEach(vm.spots) { spot in
                    Button { vm.revealPath(spot.path) } label: {
                        HStack {
                            Text(spot.label).font(.callout)
                            Spacer()
                            if spot.restricted {
                                Image(systemName: "lock").foregroundStyle(.orange)
                            } else if let size = spot.size {
                                Text(Self.fmt(size))
                                    .font(.caption).monospacedDigit()
                                    .foregroundStyle(.secondary)
                            } else {
                                ProgressView().controlSize(.mini)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(spot.path)
                }
            }
            if !vm.snapshots.isEmpty {
                Section("APFS snapshots") {
                    Label("\(vm.snapshots.count) local Time Machine snapshot(s) hold space",
                          systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.orange)
                    ForEach(vm.snapshots, id: \.self) { name in
                        Text(name.replacingOccurrences(of: "com.apple.TimeMachine.", with: ""))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func sidebarButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentTeal)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            usageBar
            errorBanner
            if vm.scanning {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(vm.adminScanRunning
                         ? "Scanning as administrator… \(vm.progress.files) items"
                         : "Scanning… \(vm.progress.files) items").font(.callout)
                    if vm.bytesPerSec > 0 {
                        Text("\(scanRateString(vm.bytesPerSec)) · \(Int(vm.filesPerSec)) items/s"
                             + (vm.scanETA.map { " · ~\(scanETAString($0)) left" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Text(vm.progress.currentPath)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 420)
                    Button("Cancel", role: .cancel) { vm.cancelScan() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showBiggest && vm.root != nil {
                biggestFilesView
            } else if let current = vm.current {
                results(current)
            } else {
                ContentUnavailableView("No scan yet",
                    systemImage: "internaldrive",
                    description: Text("Pick a scan target in the sidebar — Home, the whole disk, or any folder."))
            }
        }
    }

    /// DaisyDisk-style capacity strip: really-used / purgeable / free.
    private var usageBar: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let total = max(Double(vm.totalBytes), 1)
                let realUsed = max(0.0, Double(vm.totalBytes) - Double(vm.freeBytes) - Double(vm.purgeableBytes))
                let wUsed = geo.size.width * realUsed / total
                let wPurge = geo.size.width * Double(vm.purgeableBytes) / total
                HStack(spacing: 1) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentTeal)
                        .frame(width: max(wUsed, 0))
                    RoundedRectangle(cornerRadius: 2).fill(Color.orange.opacity(0.8))
                        .frame(width: max(wPurge, 0))
                    RoundedRectangle(cornerRadius: 2).fill(.quaternary)
                }
            }
            .frame(height: 10)
            HStack(spacing: 14) {
                legend(Color.accentTeal, "Used")
                if vm.purgeableBytes > 0 {
                    legend(Color.orange.opacity(0.8),
                           "Purgeable \(Self.fmt(vm.purgeableBytes))")
                }
                legend(Color.gray.opacity(0.25), "Free \(Self.fmt(vm.freeBytes))")
                Spacer()
                Text(Self.fmt(vm.totalBytes)).font(.caption2)
                    .monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let msg = vm.error {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(msg).font(.caption)
                    .lineLimit(3)
                Spacer()
                Button("Privacy Settings") {
                    NSWorkspace.shared.open(URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
                .controlSize(.small)
                Button { vm.error = nil } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
        }
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func results(_ current: DiskNode) -> some View {
        VStack(spacing: 0) {
            if vm.lastFreed > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Freed \(Self.fmt(vm.lastFreed)) — held in Trash").font(.callout)
                    Spacer()
                    Button {
                        vm.emptyTrash()
                    } label: {
                        if vm.emptyingTrash {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Empty Trash\(vm.trashBytes > 0 ? " (\(Self.fmt(vm.trashBytes)))" : "")",
                                  systemImage: "trash.slash")
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(vm.emptyingTrash)
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Color.green.opacity(0.1))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            HStack(spacing: 10) {
                if current.id != vm.root?.id {
                    Button { vm.drillUp() } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless).foregroundStyle(Color.accentTeal)
                }
                Text(current.path)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(Self.fmt(current.size)).font(.title3).monospacedDigit()
                Button("Rescan") { vm.startScan(current.path) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()

            let children = (current.children ?? []).filter { $0.size > 0 }
            TreemapView(nodes: Array(children.prefix(24))) { vm.drill($0) }
                .frame(minHeight: 220)
                .padding(12)

            Table(children, selection: $selection) {
                TableColumn("Name") { child in
                    HStack(spacing: 6) {
                        Image(systemName: child.isDirectory ? "folder.fill" : "doc")
                            .foregroundStyle(child.isDirectory ? Color.accentTeal : .secondary)
                        Text(child.name).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(vm.isStaged(child) ? .secondary : .primary)
                            .strikethrough(vm.isStaged(child))
                        if child.restricted {
                            Image(systemName: "lock.fill")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    .draggable(DraggedNode(child))
                }
                TableColumn("Size") { child in
                    Text(Self.fmt(child.size)).monospacedDigit()
                }
                .width(90)
                .alignment(.trailing)
            }
            .contextMenu(forSelectionType: DiskNode.ID.self) { ids in
                if let id = ids.first,
                   let node = children.first(where: { $0.id == id }) {
                    Button("Quick Look") { quickLook(node) }
                    Button("Reveal in Finder") { vm.reveal(node) }
                    if node.isDirectory {
                        Button("Drill down") { vm.drill(node) }
                        Button("Scan this folder") { vm.startScan(node.path) }
                    }
                    Divider()
                    Button("Move to Trash", role: .destructive) { vm.stage(node) }
                }
            } primaryAction: { ids in
                if let id = ids.first,
                   let node = children.first(where: { $0.id == id }),
                   node.isDirectory { vm.drill(node) }
            }

            // Scan-as-you-go: a drilled dir we couldn't see inside gets a
            // dedicated scan button instead of a dead end.
            if current.isDirectory && children.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: current.restricted ? "lock" : "questionmark.folder")
                        .foregroundStyle(.secondary)
                    Text(current.restricted
                         ? "This folder is restricted. A dedicated scan may see more with the right permissions."
                         : "Nothing scanned inside here.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Scan this folder") { vm.startScan(current.path) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.vertical, 12)
            }

            if let id = selection.first,
               let sel = children.first(where: { $0.id == id }) {
                Divider()
                HStack(spacing: 12) {
                    Text(sel.name).font(.callout)
                        .lineLimit(1).truncationMode(.middle)
                    Text(Self.fmt(sel.size))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button { vm.reveal(sel) } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    if sel.isDirectory {
                        Button { vm.drill(sel) } label: {
                            Label("Drill down", systemImage: "arrow.down.right")
                        }
                    }
                    Button(role: .destructive) { vm.stage(sel) } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .padding(.horizontal, 16).padding(.vertical, 8)
            }

            Divider()
            DeleteCollector(vm: vm)
        }
        .overlay { shortcutButtons }
    }

    private func selectedNode() -> DiskNode? {
        guard let id = selection.first else { return nil }
        return vm.node(withID: id) ?? vm.biggestFiles.first { $0.id == id }
    }

    /// Flat top-files list for the whole scanned tree.
    private var biggestFilesView: some View {
        VStack(spacing: 0) {
            if vm.lastFreed > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Freed \(Self.fmt(vm.lastFreed)) — held in Trash").font(.callout)
                    Spacer()
                    Button {
                        vm.emptyTrash()
                    } label: {
                        if vm.emptyingTrash {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Empty Trash\(vm.trashBytes > 0 ? " (\(Self.fmt(vm.trashBytes)))" : "")",
                                  systemImage: "trash.slash")
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(vm.emptyingTrash)
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Color.green.opacity(0.1))
            }
            HStack(spacing: 10) {
                Button { showBiggest = false } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless).foregroundStyle(Color.accentTeal)
                Text("Biggest files").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text("\(vm.biggestFiles.count) files").font(.caption)
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()

            Table(vm.biggestFiles, selection: $selection) {
                TableColumn("Name") { file in
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                            .foregroundStyle(.secondary)
                        Text(file.name).lineLimit(1).truncationMode(.middle)
                            .strikethrough(vm.isStaged(file))
                            .foregroundStyle(vm.isStaged(file) ? .secondary : .primary)
                    }
                    .draggable(DraggedNode(file))
                }
                TableColumn("Location") { file in
                    Text(URL(fileURLWithPath: file.path).deletingLastPathComponent().path)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                TableColumn("Size") { file in
                    Text(Self.fmt(file.size)).monospacedDigit()
                }
                .width(90)
                .alignment(.trailing)
            }
            .contextMenu(forSelectionType: DiskNode.ID.self) { ids in
                if let id = ids.first,
                   let file = vm.biggestFiles.first(where: { $0.id == id }) {
                    Button("Quick Look") { quickLook(file) }
                    Button("Reveal in Finder") { vm.reveal(file) }
                    Divider()
                    Button("Move to Trash", role: .destructive) { vm.stage(file) }
                }
            } primaryAction: { ids in
                if let id = ids.first,
                   let file = vm.biggestFiles.first(where: { $0.id == id }) {
                    quickLook(file)
                }
            }

            Divider()
            DeleteCollector(vm: vm)
        }
        .overlay { shortcutButtons }
    }

    /// Space = Quick Look, ⌫ = hold for delete, ⌘⏎ = reveal in Finder.
    private var shortcutButtons: some View {
        HStack {
            Button("") { selectedNode().map(quickLook) }
                .keyboardShortcut(.space, modifiers: [])
            Button("") { selectedNode().map(vm.stage) }
                .keyboardShortcut(.delete, modifiers: [])
            Button("") { selectedNode().map(vm.reveal) }
                .keyboardShortcut(.return, modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .hidden()
    }

    private func quickLook(_ node: DiskNode) {
        QuickLookController.shared.preview([URL(fileURLWithPath: node.path)])
    }

    private static func fmt(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary)
    }
}

/// DaisyDisk-style trash collector: drag items in to hold them, press
/// Delete and a garbage truck runs them into the bin; Undo plays a
/// restock animation instead — nothing is deleted until Delete is hit.
private struct DeleteCollector: View {
    @ObservedObject var vm: DiskAnalyzerViewModel
    @State private var targeted = false
    @State private var truckX: CGFloat = 0
    @State private var chipsTipped = false
    @State private var chipsRestocked = false

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 12) {
                binIcon

                if vm.staged.isEmpty && vm.collectorPhase == .collecting {
                    Text("Drag items here to hold them")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    chipStrip
                }
                Spacer()

                if !vm.staged.isEmpty || vm.collectorPhase != .collecting {
                    Text(fmtBytes(vm.stagedBytes)).font(.callout).monospacedDigit()
                    actionButtons
                }

                truck(in: geo.size.width)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(targeted ? Color.accentTeal.opacity(0.12) : .clear)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(targeted ? Color.accentTeal : .secondary.opacity(0.3),
                                  style: StrokeStyle(lineWidth: 1, dash: [5]))
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(height: 44)
        .padding(.horizontal, 12).padding(.bottom, 8)
        .dropDestination(for: DraggedNode.self) { items, _ in
            var handled = false
            for item in items {
                if let n = vm.node(withID: item.id) { vm.stage(n); handled = true }
            }
            return handled
        } isTargeted: { targeted = $0 }
        .onChange(of: vm.collectorPhase) { _, phase in
            switch phase {
            case .emptying: runTruck()
            case .restocking: runRestock()
            case .collecting:
                chipsTipped = false; chipsRestocked = false; truckX = 0
            }
        }
    }

    private var binIcon: some View {
        Image(systemName: vm.staged.isEmpty ? "trash" : "trash.fill")
            .font(.title3)
            .symbolEffect(.bounce, value: vm.staged.count)
            .foregroundStyle(targeted ? Color.accentTeal : .secondary)
    }

    private var chipStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(vm.staged.enumerated()), id: \.element.id) { index, node in
                    chip(node, index: index)
                }
            }
        }
        // Truck run: chips collapse toward the bin and vanish.
        .opacity(chipsTipped ? 0 : 1)
        .offset(y: chipsTipped ? 10 : 0)
        .scaleEffect(chipsTipped ? 0.2 : 1, anchor: .leading)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if vm.collectorPhase == .collecting {
            Button { vm.requestRestore() } label: {
                Label("Put back", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered).controlSize(.small)
            Button(role: .destructive) { vm.requestCommit() } label: {
                Label("Delete (\(vm.staged.count))", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
        }
    }

    @ViewBuilder
    private func truck(in width: CGFloat) -> some View {
        if vm.collectorPhase == .emptying {
            Text("🚚")
                .font(.system(size: 22))
                .offset(x: truckX)           // drives left, into the bin
                .onAppear {
                    withAnimation(.easeIn(duration: 0.7)) {
                        truckX = -(width - 60)
                    }
                    withAnimation(.easeOut(duration: 0.4).delay(0.75)) {
                        chipsTipped = true
                    }
                }
        }
    }

    private func runTruck() { truckX = 0 }

    private func runRestock() {
        chipsRestocked = true
    }

    private func chip(_ node: DiskNode, index: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                .font(.caption2).foregroundStyle(.secondary)
            Text(node.name).font(.caption).lineLimit(1)
            if vm.collectorPhase == .collecting {
                Button { vm.unstage(node) } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
        // Restock: each chip arcs back up toward the table, staggered.
        .offset(x: chipsRestocked ? CGFloat(index * -6) : 0,
                y: chipsRestocked ? -44 : 0)
        .rotationEffect(.degrees(chipsRestocked ? (index.isMultiple(of: 2) ? -14 : 10) : 0))
        .scaleEffect(chipsRestocked ? 0.55 : 1)
        .opacity(chipsRestocked ? 0 : 1)
        .animation(.spring(response: 0.55, dampingFraction: 0.75)
                       .delay(Double(index) * 0.07),
                   value: chipsRestocked)
    }

    private func fmtBytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary)
    }
}
