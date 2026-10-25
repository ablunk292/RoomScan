import SwiftUI

/// Top-down drawing of a room: walls with their lengths, doors and windows, and numbered item pins.
struct FloorPlanView: View {
    let room: Room
    var useFeet: Bool = Units.useFeet

    var body: some View {
        Canvas { context, size in
            let allPoints = room.outline + room.items.compactMap(\.position)
            guard room.outline.count >= 2, let frame = Frame(points: allPoints, size: size, inset: 36) else {
                context.draw(Text("No floor outline").foregroundStyle(.secondary),
                             at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }

            var floor = Path()
            floor.addLines(room.outline.map(frame.map))
            floor.closeSubpath()
            context.fill(floor, with: .color(.accentColor.opacity(0.12)))
            context.stroke(floor, with: .color(.primary), style: StrokeStyle(lineWidth: 3, lineJoin: .round))

            for opening in room.openings {
                var path = Path()
                path.move(to: frame.map(opening.start))
                path.addLine(to: frame.map(opening.end))
                let color: Color = switch opening.kind {
                case .door: .orange
                case .window: .cyan
                case .opening: .gray
                }
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            }

            let lengths = room.wallLengths
            for (index, length) in lengths.enumerated() {
                let a = room.outline[index]
                let b = room.outline[(index + 1) % room.outline.count]
                let label = Text(Units.length(length, feet: useFeet))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                context.draw(label, at: frame.labelPoint(a, b, polygon: room.outline))
            }

            for (index, item) in room.items.enumerated() {
                guard let position = item.position else { continue }
                let center = frame.map(position)
                let circle = Path(ellipseIn: CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20))
                context.fill(circle, with: .color(item.isRequested ? .green : .teal))
                context.draw(Text("\(index + 1)").font(.caption2.bold()).foregroundStyle(.white), at: center)
            }
        }
        .accessibilityLabel("Floor plan of \(room.name)")
    }
}

/// Fits floor coordinates (meters) into the drawing area, keeping proportions.
private struct Frame {
    let minX: Double
    let minY: Double
    let scale: Double
    let offset: CGPoint

    init?(points: [Point2D], size: CGSize, inset: Double) {
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        let width = max(maxX - minX, 0.01)
        let height = max(maxY - minY, 0.01)
        let available = CGSize(width: size.width - inset * 2, height: size.height - inset * 2)
        guard available.width > 0, available.height > 0 else { return nil }
        scale = min(available.width / width, available.height / height)
        self.minX = minX
        self.minY = minY
        offset = CGPoint(
            x: (size.width - width * scale) / 2,
            y: (size.height - height * scale) / 2
        )
    }

    func map(_ p: Point2D) -> CGPoint {
        CGPoint(x: offset.x + (p.x - minX) * scale, y: offset.y + (p.y - minY) * scale)
    }

    /// Spot for a wall's length label, just outside the room.
    func labelPoint(_ a: Point2D, _ b: Point2D, polygon: [Point2D]) -> CGPoint {
        let mid = map(Geometry.midpoint(a, b))
        let pa = map(a)
        let pb = map(b)
        let dx = pb.x - pa.x
        let dy = pb.y - pa.y
        let length = max(hypot(dx, dy), 0.001)
        var normal = CGPoint(x: -dy / length, y: dx / length)
        // Point the label away from the room's center.
        let centerX = polygon.map(\.x).reduce(0, +) / Double(polygon.count)
        let centerY = polygon.map(\.y).reduce(0, +) / Double(polygon.count)
        let center = map(Point2D(x: centerX, y: centerY))
        if (mid.x - center.x) * normal.x + (mid.y - center.y) * normal.y < 0 {
            normal = CGPoint(x: -normal.x, y: -normal.y)
        }
        return CGPoint(x: mid.x + normal.x * 16, y: mid.y + normal.y * 16)
    }
}
