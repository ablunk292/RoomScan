import Foundation

/// Cleans up hand-mapped floor plans: squares off walls that are nearly at right angles and
/// pulls neighboring rooms together so they meet at shared walls. Phone tracking without
/// LiDAR drifts a little as you walk, so rooms come out slightly skewed and apart.
enum Layout {
    /// Thickness assumed for an interior wall between two rooms (about 4.5 inches).
    static let wallThickness = 0.12
    /// Walls within this angle of the house's main directions are squared up.
    static let squareTolerance = 15.0 * .pi / 180
    /// Rooms are pulled together only when their walls are already this close.
    static let snapDistance = 0.6

    /// Squares every corner-mapped room to the house's main directions, then snaps rooms together.
    static func tidy(_ rooms: [Room]) -> [Room] {
        let angle = dominantAngle(of: rooms)
        var result = rooms.map { room -> Room in
            guard room.method == .cornerTap else { return room }
            var squared = room
            squared.outline = squaredOutline(room.outline, angle: angle)
            return squared
        }
        for index in result.indices.dropFirst() {
            result[index] = snapped(result[index], to: Array(result[..<index]), angle: angle)
        }
        return result
    }

    /// The direction most walls follow, between 0 and 90 degrees. Angles are compared four
    /// times over so walls at right angles to each other count toward the same direction.
    static func dominantAngle(of rooms: [Room]) -> Double {
        var sumX = 0.0
        var sumY = 0.0
        for room in rooms {
            for (a, b) in edges(of: room.outline) {
                let length = Geometry.distance(a, b)
                let theta = atan2(b.y - a.y, b.x - a.x)
                sumX += length * cos(4 * theta)
                sumY += length * sin(4 * theta)
            }
        }
        guard sumX != 0 || sumY != 0 else { return 0 }
        return atan2(sumY, sumX) / 4
    }

    // MARK: Squaring

    private enum Line {
        case horizontal(y: Double)
        case vertical(x: Double)
        case other(Point2D, Point2D)
    }

    /// Makes walls that are nearly along the main directions exactly so, and moves each corner
    /// to where its two walls now meet. Angled walls (bay windows, 45° corners) are left alone.
    static func squaredOutline(_ outline: [Point2D], angle: Double) -> [Point2D] {
        guard outline.count >= 3 else { return outline }
        var points = outline.map { rotate($0, by: -angle) }

        // Corners between two walls that run the same way are not real corners; drop them.
        var changed = true
        while changed, points.count > 3 {
            changed = false
            let lines = edges(of: points).map(classify)
            for i in points.indices {
                let before = lines[(i - 1 + points.count) % points.count]
                let after = lines[i]
                if sameDirection(before, after) {
                    points.remove(at: i)
                    changed = true
                    break
                }
            }
        }

        let lines = edges(of: points).map(classify)
        var squared: [Point2D] = []
        for i in points.indices {
            let before = lines[(i - 1 + points.count) % points.count]
            let after = lines[i]
            squared.append(intersection(before, after) ?? points[i])
        }
        guard Geometry.area(of: squared) > 0.5 else { return outline }
        return squared.map { rotate($0, by: angle) }
    }

    private static func classify(_ edge: (Point2D, Point2D)) -> Line {
        let (a, b) = edge
        var theta = atan2(b.y - a.y, b.x - a.x).truncatingRemainder(dividingBy: .pi)
        if theta < 0 { theta += .pi }
        if theta < squareTolerance || theta > .pi - squareTolerance {
            return .horizontal(y: (a.y + b.y) / 2)
        }
        if abs(theta - .pi / 2) < squareTolerance {
            return .vertical(x: (a.x + b.x) / 2)
        }
        return .other(a, b)
    }

    private static func sameDirection(_ a: Line, _ b: Line) -> Bool {
        switch (a, b) {
        case (.horizontal, .horizontal), (.vertical, .vertical): return true
        default: return false
        }
    }

    private static func intersection(_ a: Line, _ b: Line) -> Point2D? {
        switch (a, b) {
        case let (.horizontal(y), .vertical(x)), let (.vertical(x), .horizontal(y)):
            return Point2D(x: x, y: y)
        default:
            let (p1, p2) = endpoints(of: a)
            let (p3, p4) = endpoints(of: b)
            let d = (p1.x - p2.x) * (p3.y - p4.y) - (p1.y - p2.y) * (p3.x - p4.x)
            guard abs(d) > 1e-9 else { return nil }
            let t = ((p1.x - p3.x) * (p3.y - p4.y) - (p1.y - p3.y) * (p3.x - p4.x)) / d
            return Point2D(x: p1.x + t * (p2.x - p1.x), y: p1.y + t * (p2.y - p1.y))
        }
    }

    private static func endpoints(of line: Line) -> (Point2D, Point2D) {
        switch line {
        case .horizontal(let y): return (Point2D(x: 0, y: y), Point2D(x: 1, y: y))
        case .vertical(let x): return (Point2D(x: x, y: 0), Point2D(x: x, y: 1))
        case .other(let a, let b): return (a, b)
        }
    }

    // MARK: Snapping

    /// Moves a room so its walls meet nearby walls of rooms already placed: back to back
    /// across an interior wall, or in line along a shared outside wall.
    static func snapped(_ room: Room, to placed: [Room], angle: Double) -> Room {
        guard !placed.isEmpty, room.outline.count >= 3 else { return room }
        let mine = axisWalls(of: room, angle: angle)
        let theirs = placed.flatMap { axisWalls(of: $0, angle: angle) }

        var bestShift: [Bool: Double] = [:]   // keyed by "is horizontal wall"
        for wall in mine {
            for other in theirs where other.horizontal == wall.horizontal {
                let overlap = min(wall.end, other.end) - max(wall.start, other.start)
                let target: Double
                if wall.inside != other.inside, overlap > 0.3 {
                    // Facing each other across an interior wall.
                    target = other.offset + (wall.inside > 0 ? wallThickness : -wallThickness)
                } else if wall.inside == other.inside, overlap < 0.3 {
                    // Rooms side by side along the same outside wall.
                    target = other.offset
                } else {
                    continue
                }
                let shift = target - wall.offset
                if abs(shift) < snapDistance, abs(shift) < abs(bestShift[wall.horizontal] ?? .infinity) {
                    bestShift[wall.horizontal] = shift
                }
            }
        }

        // Shifts were found in the squared-up frame; turn them back into map directions.
        let along = Point2D(x: cos(angle), y: sin(angle))
        let across = Point2D(x: -sin(angle), y: cos(angle))
        let dy = bestShift[true] ?? 0     // horizontal walls move up or down
        let dx = bestShift[false] ?? 0    // vertical walls move left or right
        return room.translated(dx: along.x * dx + across.x * dy, dy: along.y * dx + across.y * dy)
    }

    private struct AxisWall {
        var horizontal: Bool
        /// The wall's y (horizontal walls) or x (vertical walls).
        var offset: Double
        /// Where the wall runs along the other axis.
        var start: Double
        var end: Double
        /// +1 if the room lies on the positive side of the wall, -1 if negative.
        var inside: Double
    }

    private static func axisWalls(of room: Room, angle: Double) -> [AxisWall] {
        let points = room.outline.map { rotate($0, by: -angle) }
        guard let center = Geometry.center(of: points) else { return [] }
        return edges(of: points).compactMap { edge -> AxisWall? in
            let (a, b) = edge
            switch classify(edge) {
            case .horizontal(let y):
                return AxisWall(horizontal: true, offset: y, start: min(a.x, b.x), end: max(a.x, b.x),
                                inside: center.y > y ? 1 : -1)
            case .vertical(let x):
                return AxisWall(horizontal: false, offset: x, start: min(a.y, b.y), end: max(a.y, b.y),
                                inside: center.x > x ? 1 : -1)
            case .other:
                return nil
            }
        }
    }

    // MARK: Helpers

    static func edges(of points: [Point2D]) -> [(Point2D, Point2D)] {
        guard points.count >= 2 else { return [] }
        return points.indices.map { (points[$0], points[($0 + 1) % points.count]) }
    }

    static func rotate(_ p: Point2D, by angle: Double, around center: Point2D = Point2D(x: 0, y: 0)) -> Point2D {
        let c = cos(angle)
        let s = sin(angle)
        let dx = p.x - center.x
        let dy = p.y - center.y
        return Point2D(x: center.x + dx * c - dy * s, y: center.y + dx * s + dy * c)
    }
}

extension Room {
    /// The room turned around its own center, with its doors, windows and items.
    func rotated(by angle: Double) -> Room {
        guard let center = Geometry.center(of: outline) else { return self }
        func turn(_ p: Point2D) -> Point2D { Layout.rotate(p, by: angle, around: center) }
        var room = self
        room.outline = outline.map(turn)
        room.openings = openings.map { opening in
            var moved = opening
            moved.start = turn(opening.start)
            moved.end = turn(opening.end)
            return moved
        }
        room.items = items.map { item in
            var moved = item
            moved.position = item.position.map(turn)
            return moved
        }
        return room
    }
}
