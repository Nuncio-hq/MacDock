import SwiftUI

struct ClipboardModule: DockModule {
    let id = "clipboard"
    let title = "Clipboard"
    let systemImage = "doc.on.clipboard"
    func makeView() -> some View { ClipboardView() }
}

struct ClipboardView: View {
    @StateObject private var store = ClipboardStore()
    @State private var query = ""

    private var filtered: [ClipboardItem] {
        query.isEmpty ? store.items
                      : store.items.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search", text: $query).textFieldStyle(.roundedBorder)
                Menu {
                    Button("Paste as Plain Text", action: pastePlainFirst)
                    Divider()
                    Button("Clear Unpinned", role: .destructive) { store.clearUnpinned() }
                } label: { Image(systemName: "ellipsis.circle") }
            }
            .padding(8)

            if filtered.isEmpty {
                ContentUnavailableView("No Clipboard History",
                                       systemImage: "doc.on.clipboard",
                                       description: Text("Copy something and it shows up here."))
            } else {
                List {
                    ForEach(filtered) { item in
                        ClipboardRow(item: item) {
                            store.copyBack(item)
                        } onPin: {
                            store.togglePin(item)
                        } onDelete: {
                            store.remove(item)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .onAppear { store.start() }
        .onDisappear { store.stop() }
    }

    private func pastePlainFirst() {
        guard let first = store.items.first else { return }
        store.copyBack(first, plain: true)
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    let onCopy: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text).lineLimit(2)
                Text(item.copiedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if item.pinned { Image(systemName: "pin.fill").font(.caption2) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onCopy)
        .contextMenu {
            Button("Copy", action: onCopy)
            Button(item.pinned ? "Unpin" : "Pin", action: onPin)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}
