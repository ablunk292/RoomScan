import SwiftUI

/// Top-down drawing of one room or a whole house.
///
/// With `showDetails`, each wall is labeled with its length and items are numbered pins
/// (used for a single room). Without it, each room is labeled with its name and area
/// (used for the whole-house plan).
struct FloorPlanView: View {
    let rooms: [Room]
    var showDetails = true
    var useFeet: Bool = Units.useFeet

    var body: some View {
        Canvas { context, size in
            let outlines = rooms.filter { $0.outline.count >= 2 }
            let allPoints = outlines.flatMap(\.outline) + (showDetails ? rooms.flatMap { $0.items.compactMap(\.position) } : [])
            guard !outlines.isEmpty, let frame = PlanFrame(points: allPoints, size: size, inset: showDetails ? 36 : 16) else {
                context.draw(Text("No floor outline").foregroundStyle(.secondary),
                             at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }

            for room in outlines {
                var floor = Path()
                floor.addLines(room.outline.map(frame.map))
                floor.closeSubpath()
                context.fill(floor, with: .color(.accentColor.opacity(0.12)))
                context.stroke(floor, with: .color(.primary), style: StrokeStyle(lineWidth: showDetails ? 3 : 2, lineJoin: .round))

                for opening in room.openings {
                    var path = Path()
                    path.move(to: frame.map(opening.start))
                    path.addLine(to: frame.map(opening.end))
                    let color: Color = switch opening.kind {
                    case .door: .orange
                    case .window: .cyan
                    case .opening: .gray
                    }
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: showDetails ? 6 : 4, lineCap: .round))
                }
            }

            if showDetails {
                drawDetails(in: &context, frame: frame)
            } else {
                for room in outlines {
                    guard let center = Geometry.center(of: room.outline) else { continue }
                    let label = Text("\(room.name)\n\(Units.area(room.area, feet: useFeet))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary)
                    context.draw(label, at: frame.map(center))
                }
            }
        }
        .accessibilityLabel("Floor plan of \(rooms.map(\.name).joined(separator: ", "))")
    }

    private func drawDetails(in context: inout GraphicsContext, frame: PlanFrame) {
        for room in rooms where room.outline.count >= 2 {
            for (index, length) in room.wallLengths.enumerated() {
                let a = room.outline[index]
                let b = room.outline[(index + 1) % room.outline.count]
                let label = Text(Units.length(length, feet: useFeet))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                context.draw(label, at: frame.labelPoint(a, b, polygon: room.outline))
            }
        }
        for room in rooms {
            for (index, item) in room.items.enumerated() {
                guard let position = item.position else { continue }
                let center = frame.map(position)
                let circle = Path(ellipseIn: CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20))
                context.fill(circle, with: .color(ItemColors.color(for: item)))
                context.draw(Text("\(index + 1)").font(.caption2.bold()).foregroundStyle(.white), at: center)
            }
        }
    }
}

enum ItemColors {
    static func color(for item: RoomItem) -> Color {
        if item.isRequested { return .green }
        return item.detectedAutomatically ? .purple : .teal
    }
}

/// Fits floor coordinates (meters) into the drawing area, keeping proportions.
struct PlanFrame {
    let minX: Double
    let minY: Double
    let scale: Double
    let offset: CGPoint

    init?(points: [Point2D], size: CGSize, inset: Double) {
        guard let bounds = Geometry.bounds(of: points) else { return nil }
        let width = max(bounds.maxX - bounds.minX, 0.01)
        let height = max(bounds.maxY - bounds.minY, 0.01)
        let availableWidth = Double(size.width) - inset * 2
        let availableHeight = Double(size.height) - inset * 2
        guard availableWidth > 0, availableHeight > 0 else { return nil }
        scale = min(availableWidth / width, availableHeight / height)
        minX = bounds.minX
        minY = bounds.minY
        offset = CGPoint(
            x: (Double(size.width) - width * scale) / 2,
            y: (Double(size.height) - height * scale) / 2
        )
    }

    func map(_ p: Point2D) -> CGPoint {
        CGPoint(x: offset.x + (p.x - minX) * scale, y: offset.y + (p.y - minY) * scale)
    }

    /// Screen point back to floor coordinates.
    func unmap(_ point: CGPoint) -> Point2D {
        Point2D(x: (Double(point.x) - Double(offset.x)) / scale + minX,
                y: (Double(point.y) - Double(offset.y)) / scale + minY)
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
        let center = map(Geometry.center(of: polygon) ?? Geometry.midpoint(a, b))
        if (mid.x - center.x) * normal.x + (mid.y - center.y) * normal.y < 0 {
            normal = CGPoint(x: -normal.x, y: -normal.y)
        }
        return CGPoint(x: mid.x + normal.x * 16, y: mid.y + normal.y * 16)
    }
}
