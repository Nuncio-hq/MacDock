import SwiftUI
import AppKit

/// Full-window disk analyzer ("Storage Manager") — the menubar panel stays a
/// quick view; this is where actual cleanup work happens.
struct StorageManagerView: View {
    @StateObject private var vm = DiskAnalyzerViewModel()
    @State private var selection = Set<DiskNode.ID>()

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
                sidebarButton("Folder…", icon: "folder.badge.plus") { vm.pickFolder() }
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
        if vm.scanning {
            VStack(spacing: 12) {
                ProgressView()
                Text("Scanning… \(vm.progress.files) items").font(.callout)
                Text(vm.progress.currentPath)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 420)
                Button("Cancel", role: .cancel) { vm.cancelScan() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let current = vm.current {
            results(current)
        } else {
            ContentUnavailableView("No scan yet",
                systemImage: "internaldrive",
                description: Text("Pick a scan target in the sidebar — Home, the whole disk, or any folder."))
        }
    }

    private func results(_ current: DiskNode) -> some View {
        VStack(spacing: 0) {
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
                    Button("Reveal in Finder") { vm.reveal(node) }
                    if node.isDirectory { Button("Drill down") { vm.drill(node) } }
                    Divider()
                    Button("Move to Trash", role: .destructive) { vm.stage(node) }
                }
            } primaryAction: { ids in
                if let id = ids.first,
                   let node = children.first(where: { $0.id == id }),
                   node.isDirectory { vm.drill(node) }
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
    }

    private static func fmt(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary)
    }
}

/// DaisyDisk-style trash collector: drag items in, see the pending total,
/// get a short countdown to undo before they're really moved to Trash.
private struct DeleteCollector: View {
    @ObservedObject var vm: DiskAnalyzerViewModel
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: vm.staged.isEmpty ? "trash" : "trash.fill")
                .font(.title3)
                .symbolEffect(.bounce, value: vm.staged.count)
                .foregroundStyle(targeted ? Color.accentTeal : .secondary)

            if vm.staged.isEmpty {
                Text("Drag items here to delete")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(vm.staged) { chip($0) }
                    }
                }
            }
            Spacer()

            if !vm.staged.isEmpty {
                Text(fmtBytes(vm.stagedBytes)).font(.callout).monospacedDigit()
                countdownRing
                Button("Undo") { vm.cancelStaged() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(targeted ? Color.accentTeal.opacity(0.12) : .clear)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(targeted ? Color.accentTeal : .secondary.opacity(0.3),
                              style: StrokeStyle(lineWidth: 1, dash: [5]))
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
        .dropDestination(for: DraggedNode.self) { items, _ in
            var handled = false
            for item in items {
                if let n = vm.node(withID: item.id) { vm.stage(n); handled = true }
            }
            return handled
        } isTargeted: { targeted = $0 }
        .animation(.spring(response: 0.3), value: vm.staged.count)
    }

    private func chip(_ node: DiskNode) -> some View {
        HStack(spacing: 4) {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                .font(.caption2).foregroundStyle(.secondary)
            Text(node.name).font(.caption).lineLimit(1)
            Button { vm.unstage(node) } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }

    private var countdownRing: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2)
            Circle()
                .trim(from: 0, to: vm.deleteCountdown / DiskAnalyzerViewModel.deleteCooldown)
                .stroke(.orange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(ceil(vm.deleteCountdown)))")
                .font(.caption2).monospacedDigit()
        }
        .frame(width: 22, height: 22)
    }

    private func fmtBytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary)
    }
}
