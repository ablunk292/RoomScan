import Foundation

/// Keeps rooms on the phone as a JSON file, with LiDAR 3D models saved next to it.
@MainActor
final class RoomStore: ObservableObject {
    @Published private(set) var rooms: [Room] = []

    private let fileURL: URL
    let modelsDirectory: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = documents.appendingPathComponent("rooms.json")
        modelsDirectory = documents.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        load()
    }

    func room(id: Room.ID) -> Room? {
        rooms.first { $0.id == id }
    }

    func add(_ room: Room) {
        rooms.insert(room, at: 0)
        save()
    }

    func update(_ room: Room) {
        guard let index = rooms.firstIndex(where: { $0.id == room.id }) else { return }
        rooms[index] = room
        save()
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            if let model = rooms[index].modelFileName {
                try? FileManager.default.removeItem(at: modelsDirectory.appendingPathComponent(model))
            }
        }
        rooms.remove(atOffsets: offsets)
        save()
    }

    func modelURL(for room: Room) -> URL? {
        room.modelFileName.map { modelsDirectory.appendingPathComponent($0) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            rooms = try JSONDecoder().decode([Room].self, from: data)
        } catch {
            print("RoomStore: could not read saved rooms: \(error)")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(rooms)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("RoomStore: could not save rooms: \(error)")
        }
    }
}
