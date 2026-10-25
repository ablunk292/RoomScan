import Foundation

enum Geometry {
    /// Area of a closed polygon (shoelace formula), in square meters.
    static func area(of points: [Point2D]) -> Double {
        guard points.count >= 3 else { return 0 }
        var sum = 0.0
        for i in points.indices {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// Length of each side of a closed polygon, starting with corner 0 to corner 1.
    static func edgeLengths(of points: [Point2D]) -> [Double] {
        guard points.count >= 2 else { return [] }
        let count = points.count == 2 ? 1 : points.count
        return (0..<count).map { i in distance(points[i], points[(i + 1) % points.count]) }
    }

    static func perimeter(of points: [Point2D]) -> Double {
        guard points.count >= 3 else { return 0 }
        return edgeLengths(of: points).reduce(0, +)
    }

    static func distance(_ a: Point2D, _ b: Point2D) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }

    static func midpoint(_ a: Point2D, _ b: Point2D) -> Point2D {
        Point2D(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /// Orders wall segments into one loop of corners by joining each wall's end to the
    /// nearest end of a remaining wall. Walls from a scan do not touch exactly, so the
    /// corner between two walls is the midpoint of their nearest ends.
    static func outline(fromWalls walls: [(Point2D, Point2D)]) -> [Point2D] {
        guard var current = walls.first else { return [] }
        var remaining = Array(walls.dropFirst())
        var corners: [Point2D] = []
        let firstStart = current.0

        while !remaining.isEmpty {
            let end = current.1
            var bestIndex = 0
            var bestReversed = false
            var bestDistance = Double.greatestFiniteMagnitude
            for (index, wall) in remaining.enumerated() {
                let toStart = distance(end, wall.0)
                let toEnd = distance(end, wall.1)
                if toStart < bestDistance {
                    bestDistance = toStart
                    bestIndex = index
                    bestReversed = false
                }
                if toEnd < bestDistance {
                    bestDistance = toEnd
                    bestIndex = index
                    bestReversed = true
                }
            }
            var next = remaining.remove(at: bestIndex)
            if bestReversed { next = (next.1, next.0) }
            corners.append(midpoint(end, next.0))
            current = next
        }
        corners.append(midpoint(current.1, firstStart))
        return corners
    }
}
