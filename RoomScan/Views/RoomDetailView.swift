import QuickLook
import SwiftUI

struct RoomDetailView: View {
    let propertyID: Property.ID
    let roomID: Room.ID

    @EnvironmentObject private var store: PropertyStore
    @AppStorage(Units.useFeetKey) private var useFeet = true
    @State private var editingItem: EditingItem?
    /// Item to open once the current editor has closed, such as a new item on top of it.
    @State private var nextItem: EditingItem?
    @State private var modelPreviewURL: URL?
    @State private var renaming = false
    @State private var newName = ""

    private struct EditingItem: Identifiable {
        let item: RoomItem
        let isNew: Bool
        var id: UUID { item.id }
    }

    var body: some View {
        if let room = store.room(roomID, in: propertyID) {
            content(for: room)
        } else {
            ContentUnavailableView("Room deleted", systemImage: "trash")
        }
    }

    private func content(for room: Room) -> some View {
        List {
            Section {
                FloorPlanView(
                    rooms: [room],
                    useFeet: useFeet,
                    onTapItem: { _, itemID in
                        if let item = room.items.first(where: { $0.id == itemID }) {
                            editingItem = EditingItem(item: item, isNew: false)
                        }
                    },
                    onTapLocation: { point in
                        editingItem = EditingItem(item: RoomItem(name: "", position: point), isNew: true)
                    }
                )
                .frame(height: 300)
                .listRowInsets(EdgeInsets())
                VStack(alignment: .leading, spacing: 6) {
                    hint("hand.tap", "Tap a numbered pin to see or change that item.")
                    hint("plus.circle", "Tap an empty spot on the plan to add an item there.")
                    hint("square.stack.3d.up", "For something on another item, like a phone on a desk, open the desk and tap Add Item on Top.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let url = store.modelURL(for: room) {
                    Button {
                        modelPreviewURL = url
                    } label: {
                        Label("View 3D model", systemImage: "cube.transparent")
                    }
                }
            }

            Section {
                Button {
                    editingItem = EditingItem(item: RoomItem(name: ""), isNew: true)
                } label: {
                    Label("Add Existing Item", systemImage: "plus")
                }
                Button {
                    editingItem = EditingItem(item: RoomItem(name: "", isRequested: true), isNew: true)
                } label: {
                    Label("Add Customer Request", systemImage: "cart.badge.plus")
                }
            } footer: {
                Text("Existing items are already in the room. Customer requests are things the customer wants added, and they go on the quote.")
            }

            itemSection("Existing items", room: room, items: room.items.filter { !$0.isRequested })
            itemSection("Customer requested", room: room, items: room.items.filter(\.isRequested))

            Section("Measurements") {
                LabeledContent("Floor area", value: Units.area(room.area, feet: useFeet))
                LabeledContent("Perimeter", value: Units.length(room.perimeter, feet: useFeet))
                CeilingHeightRow(room: room, useFeet: useFeet) { store.update($0, in: propertyID) }
                ForEach(Array(room.wallLengths.enumerated()), id: \.offset) { index, length in
                    LabeledContent("Wall \(index + 1)", value: Units.length(length, feet: useFeet))
                }
                if !room.openings.isEmpty {
                    LabeledContent("Doors", value: "\(room.openings.filter { $0.kind == .door }.count)")
                    LabeledContent("Windows", value: "\(room.openings.filter { $0.kind == .window }.count)")
                }
                LabeledContent("Captured with", value: room.method.label)
            }

            Section("Notes") {
                NotesField(room: room) { store.update($0, in: propertyID) }
            }
        }
        .navigationTitle(room.name)
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    newName = room.name
                    renaming = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: RoomReport.text(for: room, useFeet: useFeet)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(item: $editingItem, onDismiss: {
            editingItem = nextItem
            nextItem = nil
        }) { editing in
            ItemEditorView(
                item: editing.item,
                isNew: editing.isNew,
                room: room,
                onSave: { saved in save(saved, in: roomID) },
                onDelete: editing.isNew ? nil : { delete(editing.item.id, in: roomID) },
                onOpen: { item, isNew in nextItem = EditingItem(item: item, isNew: isNew) }
            )
        }
        .quickLookPreview($modelPreviewURL)
        .alert("Rename room", isPresented: $renaming) {
            TextField("Room name", text: $newName)
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, var updated = store.room(roomID, in: propertyID) else { return }
                updated.name = name
                store.update(updated, in: propertyID)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func hint(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
        }
    }

    @ViewBuilder
    private func itemSection(_ title: String, room: Room, items: [RoomItem]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(room.itemsNested(items), id: \.item.id) { entry in
                    Button {
                        editingItem = EditingItem(item: entry.item, isNew: false)
                    } label: {
                        ItemRow(item: entry.item,
                                number: (room.items.firstIndex(of: entry.item) ?? 0) + 1,
                                parentName: room.item(entry.item.parentID)?.name)
                    }
                    .foregroundStyle(.primary)
                    .padding(.leading, CGFloat(entry.depth) * 24)
                }
            }
        }
    }

    private func save(_ item: RoomItem, in roomID: Room.ID) {
        guard var room = store.room(roomID, in: propertyID) else { return }
        if let index = room.items.firstIndex(where: { $0.id == item.id }) {
            room.items[index] = item
        } else {
            room.items.append(item)
        }
        store.update(room, in: propertyID)
    }

    private func delete(_ itemID: UUID, in roomID: Room.ID) {
        guard var room = store.room(roomID, in: propertyID) else { return }
        ItemPhotos.delete(room.item(itemID)?.photoFileName)
        room.items.removeAll { $0.id == itemID }
        // Whatever sat on the deleted item stays in the room on its own.
        for index in room.items.indices where room.items[index].parentID == itemID {
            room.items[index].parentID = nil
        }
        store.update(room, in: propertyID)
    }
}

private struct ItemRow: View {
    let item: RoomItem
    let number: Int
    var parentName: String?

    private var details: String {
        var parts = [item.category]
        if !item.isRequested { parts.append(item.condition.label) }
        if let parentName { parts.insert("On \(parentName)", at: 0) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(ItemColors.color(for: item)))
                .opacity(item.position == nil ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.quantity > 1 ? "\(item.name) ×\(item.quantity)" : item.name)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let photo = ItemPhotos.image(named: item.photoFileName) {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if item.detectedAutomatically {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Found by scan")
            }
        }
    }
}

private struct CeilingHeightRow: View {
    let room: Room
    let useFeet: Bool
    let onChange: (Room) -> Void
    @State private var text = ""

    var body: some View {
        LabeledContent("Ceiling height") {
            HStack(spacing: 4) {
                TextField("—", text: $text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .onSubmit(commit)
                Text(useFeet ? "ft" : "m").foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: load)
        .onChange(of: useFeet) { load() }
        .onChange(of: text) { commit() }
    }

    private func load() {
        text = room.ceilingHeight.map { String(format: "%.1f", Units.display(fromMeters: $0, feet: useFeet)) } ?? ""
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let newValue: Double?
        if trimmed.isEmpty {
            newValue = nil
        } else if let typed = Double(trimmed.replacingOccurrences(of: ",", with: ".")) {
            newValue = Units.meters(fromDisplay: typed, feet: useFeet)
        } else {
            return
        }

        // Ignore tiny differences from rounding when the text was filled in from the saved value.
        let changed: Bool
        switch (newValue, room.ceilingHeight) {
        case (nil, nil): changed = false
        case let (new?, old?): changed = abs(new - old) > 0.005
        default: changed = true
        }
        guard changed else { return }

        var updated = room
        updated.ceilingHeight = newValue
        onChange(updated)
    }
}

private struct NotesField: View {
    let room: Room
    let onChange: (Room) -> Void
    @State private var text = ""

    var body: some View {
        TextField("What the customer said, access notes…", text: $text, axis: .vertical)
            .lineLimit(3...10)
            .onAppear { text = room.notes }
            .onChange(of: text) {
                guard text != room.notes else { return }
                var updated = room
                updated.notes = text
                onChange(updated)
            }
    }
}

/// Plain-text summary of a room for sharing by text or email.
enum RoomReport {
    static func text(for room: Room, useFeet: Bool) -> String {
        var lines = [
            room.name,
            "Floor area: \(Units.area(room.area, feet: useFeet))",
            "Perimeter: \(Units.length(room.perimeter, feet: useFeet))",
        ]
        if let ceiling = room.ceilingHeight {
            lines.append("Ceiling height: \(Units.length(ceiling, feet: useFeet))")
        }
        for (index, length) in room.wallLengths.enumerated() {
            lines.append("Wall \(index + 1): \(Units.length(length, feet: useFeet))")
        }

        let existing = room.items.filter { !$0.isRequested }
        if !existing.isEmpty {
            lines.append("")
            lines.append("Existing items:")
            lines += existing.map { "• \($0.name) ×\($0.quantity) (\($0.condition.label))\(on($0, in: room))\($0.notes.isEmpty ? "" : " — \($0.notes)")" }
        }
        let requested = room.items.filter(\.isRequested)
        if !requested.isEmpty {
            lines.append("")
            lines.append("Customer requested:")
            lines += requested.map { "• \($0.name) ×\($0.quantity)\(on($0, in: room))\($0.notes.isEmpty ? "" : " — \($0.notes)")" }
        }
        if !room.notes.isEmpty {
            lines.append("")
            lines.append("Notes: \(room.notes)")
        }
        return lines.joined(separator: "\n")
    }

    private static func on(_ item: RoomItem, in room: Room) -> String {
        room.item(item.parentID).map { ", on \($0.name)" } ?? ""
    }
}
