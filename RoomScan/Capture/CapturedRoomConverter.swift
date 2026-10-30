import Foundation
import RoomPlan
import simd

/// Turns a RoomPlan scan into RoomScan's own room format.
enum CapturedRoomConverter {
    static func room(from captured: CapturedRoom, named name: String) -> Room {
        let walls = captured.walls.map { endpoints(of: $0) }
        let outline = Geometry.outline(fromWalls: walls)
        let ceiling = captured.walls.map { Double($0.dimensions.y) }.max()

        var openings: [Opening] = []
        openings += captured.doors.map { surface in
            let (start, end) = endpoints(of: surface)
            return Opening(kind: .door, start: start, end: end)
        }
        openings += captured.windows.map { surface in
            let (start, end) = endpoints(of: surface)
            return Opening(kind: .window, start: start, end: end)
        }
        openings += captured.openings.map { surface in
            let (start, end) = endpoints(of: surface)
            return Opening(kind: .opening, start: start, end: end)
        }

        let items = captured.objects.map { object in
            let position = object.transform.columns.3
            return RoomItem(
                name: displayName(of: object.category),
                category: category(for: object.category),
                position: Point2D(x: Double(position.x), y: Double(position.z)),
                dimensions: Dimensions3D(
                    width: Double(object.dimensions.x),
                    height: Double(object.dimensions.y),
                    depth: Double(object.dimensions.z)
                ),
                detectedAutomatically: true
            )
        }

        return Room(
            name: name,
            method: .lidar,
            outline: outline,
            ceilingHeight: ceiling,
            openings: openings,
            items: items
        )
    }

    /// The two ends of a wall, door or window, seen from above.
    private static func endpoints(of surface: CapturedRoom.Surface) -> (Point2D, Point2D) {
        let center = surface.transform.columns.3
        let axis = surface.transform.columns.0
        let half = surface.dimensions.x / 2
        let a = SIMD3<Float>(center.x, center.y, center.z) - SIMD3<Float>(axis.x, axis.y, axis.z) * half
        let b = SIMD3<Float>(center.x, center.y, center.z) + SIMD3<Float>(axis.x, axis.y, axis.z) * half
        return (Point2D(x: Double(a.x), y: Double(a.z)), Point2D(x: Double(b.x), y: Double(b.z)))
    }

    /// "washerDryer" becomes "Washer dryer".
    private static func displayName(of category: CapturedRoom.Object.Category) -> String {
        let raw = String(describing: category)
        var words = ""
        for character in raw {
            if character.isUppercase { words.append(" ") }
            words.append(character.lowercased())
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private static func category(for category: CapturedRoom.Object.Category) -> String {
        switch String(describing: category) {
        case "refrigerator", "stove", "oven", "dishwasher", "washerDryer":
            return "Appliance"
        case "sink", "toilet", "bathtub":
            return "Plumbing"
        case "television":
            return "Network / AV"
        case "bed", "sofa", "chair", "table", "storage":
            return "Furniture"
        case "fireplace", "stairs":
            return "Fixture"
        default:
            return "Other"
        }
    }
}
