import Foundation

/// A house, apartment or building: the rooms mapped there, in one shared coordinate space
/// when they were scanned in the same walk.
struct Property: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var address: String = ""
    var createdAt = Date()
    var rooms: [Room] = []
    var notes: String = ""

    var totalArea: Double { rooms.reduce(0) { $0 + $1.area } }
    var itemCount: Int { rooms.reduce(0) { $0 + $1.items.count } }
    var requestedCount: Int { rooms.reduce(0) { $0 + $1.items.filter(\.isRequested).count } }

    /// Adds rooms from a new scanning session. A new session has its own coordinates, so the
    /// rooms are moved to sit beside the ones already mapped instead of on top of them.
    mutating func append(roomsFromNewSession newRooms: [Room]) {
        guard !rooms.isEmpty,
              let existing = Geometry.bounds(of: rooms.flatMap(\.outline)),
              let incoming = Geometry.bounds(of: newRooms.flatMap(\.outline)) else {
            rooms += newRooms
            return
        }
        let dx = existing.maxX + 1.0 - incoming.minX
        let dy = existing.minY - incoming.minY
        rooms += newRooms.map { $0.translated(dx: dx, dy: dy) }
    }
}

extension Room {
    func translated(dx: Double, dy: Double) -> Room {
        func move(_ p: Point2D) -> Point2D { Point2D(x: p.x + dx, y: p.y + dy) }
        var room = self
        room.outline = outline.map(move)
        room.openings = openings.map { opening in
            var moved = opening
            moved.start = move(opening.start)
            moved.end = move(opening.end)
            return moved
        }
        room.items = items.map { item in
            var moved = item
            moved.position = item.position.map(move)
            return moved
        }
        return room
    }
}
