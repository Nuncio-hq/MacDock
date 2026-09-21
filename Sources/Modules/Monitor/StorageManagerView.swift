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
                ForEach(vm.staged) { chip($0) }
            }
        }
        // Truck run: chips collapse toward the bin and vanish.
        // Restock: chips fly back up out of the bar.
        .opacity(chipsTipped ? 0 : 1)
        .offset(y: chipsTipped ? 10 : (chipsRestocked ? -34 : 0))
        .scaleEffect(chipsTipped ? 0.2 : (chipsRestocked ? 0.7 : 1),
                   anchor: chipsRestocked ? .top : .leading)
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
                .scaleEffect(x: -1)          // face left, toward the bin
                .offset(x: truckX)
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
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            chipsRestocked = true
        }
    }

    private func chip(_ node: DiskNode) -> some View {
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
    }

    private func fmtBytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary)
    }
}
