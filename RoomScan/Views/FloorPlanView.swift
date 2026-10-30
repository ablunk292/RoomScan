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

    private struct PlacedItem {
        let room: Room
        let index: Int
        let item: RoomItem
        let position: Point2D
    }

    private var placedItems: [PlacedItem] {
        rooms.flatMap { room in
            room.items.enumerated().compactMap { index, item in
                item.position.map { PlacedItem(room: room, index: index, item: item, position: $0) }
            }
        }
    }

    /// Where each pin is drawn. On a single room's plan, items sitting on another item (a phone
    /// on a desk) are fanned out around that item's pin so both can be seen and tapped.
    private func pins(in frame: PlanFrame) -> [(placed: PlacedItem, point: CGPoint, parent: CGPoint?)] {
        let base = placedItems.map { (placed: $0, point: frame.map($0.position), parent: CGPoint?.none) }
        guard showDetails else { return base }
        var result = base
        var fanned: [UUID: Int] = [:]
        for i in result.indices {
            let child = result[i].placed
            guard let parentID = child.item.parentID,
                  let parent = base.first(where: { $0.placed.room.id == child.room.id && $0.placed.item.id == parentID }),
                  hypot(parent.point.x - result[i].point.x, parent.point.y - result[i].point.y) < pinRadius * 2 else { continue }
            let k = fanned[parentID, default: 0]
            fanned[parentID] = k + 1
            let angle = -Double.pi / 4 + Double(k) * Double.pi / 3
            let distance = Double(pinRadius) * 2.4
            result[i].point = CGPoint(x: parent.point.x + cos(angle) * distance, y: parent.point.y + sin(angle) * distance)
            result[i].parent = parent.point
        }
        return result
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
        let nearest = pins(in: frame).min { a, b in
            hypot(a.point.x - location.x, a.point.y - location.y) < hypot(b.point.x - location.x, b.point.y - location.y)
        }
        if let nearest, let onTapItem,
           hypot(nearest.point.x - location.x, nearest.point.y - location.y) <= touchRadius {
            onTapItem(nearest.placed.room.id, nearest.placed.item.id)
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

        let allPins = pins(in: frame)
        for pin in allPins {
            guard let parent = pin.parent else { continue }
            var link = Path()
            link.move(to: parent)
            link.addLine(to: pin.point)
            context.stroke(link, with: .color(.secondary), lineWidth: 1.5)
        }
        for pin in allPins {
            let center = pin.point
            let r = pinRadius
            let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            context.fill(circle, with: .color(ItemColors.color(for: pin.placed.item)))
            if showDetails {
                context.stroke(circle, with: .color(.white), lineWidth: 1.5)
                context.draw(Text("\(pin.placed.index + 1)").font(.caption2.bold()).foregroundStyle(.white), at: center)
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
