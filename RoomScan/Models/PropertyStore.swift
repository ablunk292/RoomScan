import Foundation

/// Keeps properties on the phone as a JSON file, with LiDAR 3D models saved next to it.
@MainActor
final class PropertyStore: ObservableObject {
    @Published private(set) var properties: [Property] = []

    private let fileURL: URL
    let modelsDirectory: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = documents.appendingPathComponent("properties.json")
        modelsDirectory = documents.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        load(documents: documents)
    }

    func property(id: Property.ID) -> Property? {
        properties.first { $0.id == id }
    }

    func room(_ roomID: Room.ID, in propertyID: Property.ID) -> Room? {
        property(id: propertyID)?.rooms.first { $0.id == roomID }
    }

    func add(_ property: Property) {
        properties.insert(property, at: 0)
        save()
    }

    func update(_ property: Property) {
        guard let index = properties.firstIndex(where: { $0.id == property.id }) else { return }
        properties[index] = property
        save()
    }

    func update(_ room: Room, in propertyID: Property.ID) {
        guard var property = property(id: propertyID),
              let index = property.rooms.firstIndex(where: { $0.id == room.id }) else { return }
        property.rooms[index] = room
        update(property)
    }

    func deleteRoom(_ roomID: Room.ID, in propertyID: Property.ID) {
        guard var property = property(id: propertyID),
              let index = property.rooms.firstIndex(where: { $0.id == roomID }) else { return }
        removeModel(of: property.rooms[index])
        property.rooms.remove(at: index)
        update(property)
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            properties[index].rooms.forEach(removeModel)
        }
        properties.remove(atOffsets: offsets)
        save()
    }

    func modelURL(for room: Room) -> URL? {
        room.modelFileName.map { modelsDirectory.appendingPathComponent($0) }
    }

    private func removeModel(of room: Room) {
        if let url = modelURL(for: room) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func load(documents: URL) {
        if let data = try? Data(contentsOf: fileURL) {
            do {
                properties = try JSONDecoder().decode([Property].self, from: data)
            } catch {
                print("PropertyStore: could not read saved properties: \(error)")
            }
            return
        }
        // Rooms saved by the first version of the app, before houses existed.
        let oldRoomsURL = documents.appendingPathComponent("rooms.json")
        if let data = try? Data(contentsOf: oldRoomsURL),
           let rooms = try? JSONDecoder().decode([Room].self, from: data), !rooms.isEmpty {
            var imported = Property(name: "Earlier rooms")
            for room in rooms {
                imported.append(roomsFromNewSession: [room])
            }
            properties = [imported]
            save()
            try? FileManager.default.removeItem(at: oldRoomsURL)
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(properties)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("PropertyStore: could not save properties: \(error)")
        }
    }
}
