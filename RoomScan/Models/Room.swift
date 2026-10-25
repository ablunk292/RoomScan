import Foundation

/// A point on the floor, seen from above, in meters.
struct Point2D: Codable, Hashable {
    var x: Double
    var y: Double
}

struct Dimensions3D: Codable, Hashable {
    var width: Double
    var height: Double
    var depth: Double
}

enum CaptureMethod: String, Codable {
    case cornerTap
    case lidar

    var label: String {
        switch self {
        case .cornerTap: return "Corner measure"
        case .lidar: return "LiDAR scan"
        }
    }
}

enum ItemCondition: String, Codable, CaseIterable, Identifiable {
    case good
    case needsRepair
    case needsReplacement
    case outdated

    var id: Self { self }

    var label: String {
        switch self {
        case .good: return "Good"
        case .needsRepair: return "Needs repair"
        case .needsReplacement: return "Needs replacement"
        case .outdated: return "Outdated"
        }
    }
}

struct RoomItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var category: String = "Other"
    var quantity: Int = 1
    var condition: ItemCondition = .good
    /// Something the customer asked to have added, as opposed to something already in the room.
    var isRequested: Bool = false
    var notes: String = ""
    var position: Point2D?
    var dimensions: Dimensions3D?
    var detectedAutomatically: Bool = false

    static let categories = [
        "Appliance", "Electrical", "Plumbing", "HVAC", "Lighting", "Furniture",
        "Fixture", "Network / AV", "Security", "Flooring", "Window / Door", "Other",
    ]
}

enum OpeningKind: String, Codable {
    case door
    case window
    case opening
}

/// A door, window, or open doorway along a wall.
struct Opening: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: OpeningKind
    var start: Point2D
    var end: Point2D
}

struct Room: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var method: CaptureMethod
    /// Floor corners in order around the room.
    var outline: [Point2D]
    var ceilingHeight: Double?
    var openings: [Opening] = []
    var items: [RoomItem] = []
    var notes: String = ""
    /// File name of the 3D model saved by a LiDAR scan, inside the store's models folder.
    var modelFileName: String?

    var area: Double { Geometry.area(of: outline) }
    var perimeter: Double { Geometry.perimeter(of: outline) }
    var wallLengths: [Double] { Geometry.edgeLengths(of: outline) }
}
