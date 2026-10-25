import SwiftUI

/// Top-down drawing of one room or a whole house.
///
/// With `showDetails`, each wall is labeled with its length and items are numbered pins
/// (used for a single room). Without it, each room is labeled with its name and area and
/// items are small dots (used for the whole-house plan).
struct FloorPlanView: View {
    let rooms: [Room]
    var showDetails = true
    var useFeet: Bool = Units.useFeet
    /// Called when an item pin is tapped.
    var onTapItem: ((Room.ID, RoomItem.ID) -> Void)?
    /// Called when anywhere else on the plan is tapped, with the floor position.
    var onTapLocation: ((Point2D) -> Void)?

    private var outlines: [Room] { rooms.filter { $0.outline.count >= 2 } }

    private var placedItems: [(room: Room, index: Int, item: RoomItem, position: Point2D)] {
        rooms.flatMap { room in
            room.items.enumerated().compactMap { index, item in
                item.position.map { (room: room, index: index, item: item, position: $0) }
            }
        }
    }

    private func planFrame(for size: CGSize) -> PlanFrame? {
        guard !outlines.isEmpty else { return nil }
        var points = outlines.flatMap(\.outline)
        if showDetails, let bounds = Geometry.bounds(of: points) {
            // Include items near the room, but not ones a bad position put far away.
            points += placedItems.map(\.position).filter {
                $0.x > bounds.minX - 1 && $0.x < bounds.maxX + 1 && $0.y > bounds.minY - 1 && $0.y < bounds.maxY + 1
            }
        }
        return PlanFrame(points: points, size: size, inset: showDetails ? 36 : 16)
    }

    private var pinRadius: CGFloat { showDetails ? 10 : 4 }

    var body: some View {
        GeometryReader { geometry in
            let frame = planFrame(for: geometry.size)
            Canvas { context, size in
                guard let frame else {
                    context.draw(Text("No floor outline").foregroundStyle(.secondary),
                                 at: CGPoint(x: size.width / 2, y: size.height / 2))
                    return
                }
                draw(in: &context, frame: frame)
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                guard let frame else { return }
                handleTap(at: location, frame: frame)
            }
        }
        .accessibilityLabel("Floor plan of \(rooms.map(\.name).joined(separator: ", "))")
    }

    private func handleTap(at location: CGPoint, frame: PlanFrame) {
        let touchRadius = max(pinRadius, 14)
        let nearest = placedItems.min { a, b in
            hypot(frame.map(a.position).x - location.x, frame.map(a.position).y - location.y)
                < hypot(frame.map(b.position).x - location.x, frame.map(b.position).y - location.y)
        }
        if let nearest, let onTapItem,
           hypot(frame.map(nearest.position).x - location.x, frame.map(nearest.position).y - location.y) <= touchRadius {
            onTapItem(nearest.room.id, nearest.item.id)
        } else {
            onTapLocation?(frame.unmap(location))
        }
    }

    private func draw(in context: inout GraphicsContext, frame: PlanFrame) {
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
            for room in outlines {
                for (index, length) in room.wallLengths.enumerated() {
                    let a = room.outline[index]
                    let b = room.outline[(index + 1) % room.outline.count]
                    let label = Text(Units.length(length, feet: useFeet))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    context.draw(label, at: frame.labelPoint(a, b, polygon: room.outline))
                }
            }
        } else {
            for room in outlines {
                guard let center = Geometry.center(of: room.outline) else { continue }
                let label = Text("\(room.name)\n\(Units.area(room.area, feet: useFeet))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                context.draw(label, at: frame.map(center))
            }
        }

        for placed in placedItems {
            let center = frame.map(placed.position)
            let r = pinRadius
            let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            context.fill(circle, with: .color(ItemColors.color(for: placed.item)))
            if showDetails {
                context.draw(Text("\(placed.index + 1)").font(.caption2.bold()).foregroundStyle(.white), at: center)
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
