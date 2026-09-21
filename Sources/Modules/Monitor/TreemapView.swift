import SwiftUI

/// Squarified treemap of a scanned directory's immediate children.
/// Tap a rectangle to drill into that directory.
struct TreemapView: View {
    let nodes: [DiskNode]
    var onDrill: (DiskNode) -> Void

    var body: some View {
        GeometryReader { geo in
            let rects = Squarify.layout(weights: nodes.map { Double($0.size) },
                                    in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(nodes.indices, rects)), id: \.0) { i, rect in
                    let node = nodes[i]
                    let hue = Double(i % 10) / 10.0
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentTeal.opacity(0.18 + 0.5 * (1 - hue)))
                        .overlay {
                            if rect.width > 70, rect.height > 30 {
                                VStack(spacing: 2) {
                                    Text(node.name)
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(ByteCountFormatter.string(
                                        fromByteCount: Int64(node.size), countStyle: .binary))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(4)
                            }
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(.background.opacity(0.5), lineWidth: 1)
                        }
                        .frame(width: max(rect.width - 2, 1),
                               height: max(rect.height - 2, 1))
                        .position(x: rect.midX, y: rect.midY)
                        .contentShape(Rectangle())
                        .onTapGesture { if node.isDirectory { onDrill(node) } }
                        .help("\(node.path)\n\(ByteCountFormatter.string(fromByteCount: Int64(node.size), countStyle: .binary))")
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Classic squarified-treemap layout (Bruls–Huizing–van Wijk).
enum Squarify {
    static func layout(weights: [Double], in rect: CGRect) -> [CGRect] {
        let total = weights.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else {
            return Array(repeating: .zero, count: weights.count)
        }
        let scale = Double(rect.width * rect.height) / total
        var items = weights.enumerated()
            .map { (index: $0.offset, area: $0.element * scale) }
            .sorted { $0.area > $1.area }
        var rects = [CGRect?](repeating: nil, count: weights.count)
        var remaining = rect

        while !items.isEmpty {
            let side = Double(min(remaining.width, remaining.height))
            var row: [(index: Int, area: Double)] = []
            var rowSum = 0.0
            var best = Double.greatestFiniteMagnitude
            while let next = items.first {
                let cand = rowSum + next.area
                let worst = worstAspect(areas: row.map(\.area) + [next.area],
                                       sum: cand, side: side)
                if worst <= best {
                    row.append(next); rowSum = cand; best = worst
                    items.removeFirst()
                } else { break }
            }
            if row.isEmpty { row.append(items.removeFirst()); rowSum = row[0].area }

            let thickness = rowSum / side
            var offset = 0.0
            let horizontal = remaining.width >= remaining.height
            for item in row {
                let length = item.area / thickness
                let r: CGRect
                if horizontal {
                    r = CGRect(x: remaining.minX, y: remaining.minY + offset,
                               width: thickness, height: length)
                } else {
                    r = CGRect(x: remaining.minX + offset, y: remaining.minY,
                               width: length, height: thickness)
                }
                rects[item.index] = r
                offset += length
            }
            if horizontal {
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY,
                                   width: remaining.width - thickness, height: remaining.height)
            } else {
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness,
                                   width: remaining.width, height: remaining.height - thickness)
            }
        }
        return rects.map { $0 ?? .zero }
    }

    private static func worstAspect(areas: [Double], sum: Double, side: Double) -> Double {
        guard let maxA = areas.max(), let minA = areas.min(), minA > 0, sum > 0
        else { return .greatestFiniteMagnitude }
        let s2 = side * side, sum2 = sum * sum
        return max(s2 * maxA / sum2, sum2 / (s2 * minA))
    }
}
