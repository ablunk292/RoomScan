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
    /// Photo of the item where it sits in the room, inside the photos folder (see ItemPhotos).
    var photoFileName: String?
    /// The item this one sits on or belongs with, such as the desk under a phone.
    var parentID: UUID?

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

    func item(_ id: UUID?) -> RoomItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    /// Items that sit on the given item.
    func items(on parent: RoomItem) -> [RoomItem] {
        items.filter { $0.parentID == parent.id }
    }

    /// The given item and everything stacked on it, at any depth.
    func itemAndEverythingOn(_ item: RoomItem) -> Set<UUID> {
        var found: Set<UUID> = [item.id]
        var added = true
        while added {
            added = false
            for other in items where !found.contains(other.id) {
                if let parent = other.parentID, found.contains(parent) {
                    found.insert(other.id)
                    added = true
                }
            }
        }
        return found
    }

    /// Items in list order, with each item followed by the items sitting on it.
    func itemsNested(_ subset: [RoomItem]) -> [(item: RoomItem, depth: Int)] {
        let ids = Set(subset.map(\.id))
        var result: [(item: RoomItem, depth: Int)] = []
        var visited: Set<UUID> = []
        func visit(_ item: RoomItem, depth: Int) {
            guard visited.insert(item.id).inserted else { return }
            result.append((item, depth))
            for child in items(on: item) where ids.contains(child.id) {
                visit(child, depth: depth + 1)
            }
        }
        for item in subset where item.parentID.map({ !ids.contains($0) || self.item($0) == nil }) ?? true {
            visit(item, depth: 0)
        }
        // Anything left over (for example, items stacked in a loop) still shows up.
        for item in subset where !visited.contains(item.id) {
            visit(item, depth: 0)
        }
        return result
    }
}
