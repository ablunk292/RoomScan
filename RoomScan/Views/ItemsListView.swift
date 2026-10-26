import SwiftUI

/// Every item in a property (or one room), with filters and multi-select to delete or change
/// many items at once.
struct ItemsListView: View {
    let propertyID: Property.ID
    /// Show only this room's items; nil shows the whole property.
    let roomID: Room.ID?

    @EnvironmentObject private var store: PropertyStore
    @State private var search = ""
    @State private var filter = ItemFilter()
    @State private var loadedView = false
    @State private var selection: Set<UUID> = []
    @State private var editMode = EditMode.inactive
    @State private var confirmingDelete = false
    @State private var editing: (roomID: Room.ID, item: RoomItem)?
    @State private var noting: QuickNote?
    @State private var noteText = ""

    private struct Entry: Identifiable {
        let room: Room
        let item: RoomItem
        var id: UUID { item.id }
    }

    var body: some View {
        let entries = filteredEntries
        List(selection: $selection) {
            Section {
                ItemViewBar(propertyID: propertyID, unsavedFilter: filter) { view in
                    filter = view?.filter ?? ItemFilter()
                }
                filterBar
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))

            if entries.isEmpty {
                ContentUnavailableView("No matching items", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text(hasFilters ? "Try clearing some filters." : "Items you add or the AI finds show here."))
            }

            ForEach(groupedRooms(entries), id: \.room.id) { group in
                Section(roomID == nil ? group.room.name : "\(group.entries.count) items") {
                    ForEach(group.entries) { entry in
                        Group {
                            if editMode.isEditing {
                                row(entry)
                            } else {
                                Button {
                                    editing = (entry.room.id, entry.item)
                                } label: {
                                    row(entry)
                                }
                                .foregroundStyle(.primary)
                            }
                        }
                        .tag(entry.id)
                        .swipeActions(edge: .leading) {
                            Button {
                                noteText = entry.item.notes
                                noting = QuickNote(roomID: entry.room.id, item: entry.item)
                            } label: {
                                Label("Note", systemImage: "note.text")
                            }
                            .tint(.orange)
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Search items")
        .onAppear {
            // Open with the view picked for this walkthrough, once.
            guard !loadedView else { return }
            loadedView = true
            filter = ItemViews.shared.view(for: propertyID)?.filter ?? ItemFilter()
        }
        .alert("Note for \(noting?.item.name ?? "item")",
               isPresented: Binding(get: { noting != nil }, set: { if !$0 { noting = nil } })) {
            TextField("Note", text: $noteText, axis: .vertical)
            Button("Save") {
                guard let noting else { return }
                update(in: noting.roomID) { items in
                    if let index = items.firstIndex(where: { $0.id == noting.item.id }) {
                        items[index].notes = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .environment(\.editMode, $editMode)
        .navigationTitle(roomID.flatMap { store.room($0, in: propertyID)?.name } ?? "All Items")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(editMode.isEditing ? "Done" : "Select") {
                    withAnimation {
                        editMode = editMode.isEditing ? .inactive : .active
                        if !editMode.isEditing { selection = [] }
                    }
                }
            }
            if editMode.isEditing {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selection.count == entries.count && !entries.isEmpty ? "Select None" : "Select All") {
                        selection = selection.count == entries.count ? [] : Set(entries.map(\.id))
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    bulkMenu
                    Spacer()
                    Text("\(selection.count) selected").font(.footnote)
                    Spacer()
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(selection.isEmpty)
                }
            }
        }
        .confirmationDialog("Delete \(selection.count) item\(selection.count == 1 ? "" : "s")?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteSelected() }
        } message: {
            Text("Their photos are deleted too. This can't be undone.")
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let editing, let room = store.room(editing.roomID, in: propertyID) {
                ItemEditorView(item: editing.item, isNew: false, room: room,
                               onSave: { saved in update(in: editing.roomID) { items in
                                   if let index = items.firstIndex(where: { $0.id == saved.id }) { items[index] = saved }
                               } },
                               onDelete: { delete([editing.item.id]) })
            }
        }
    }

    // MARK: Filters

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(availableCategories, id: \.self) { category in
                        Button {
                            if filter.categories.contains(category) { filter.categories.remove(category) } else { filter.categories.insert(category) }
                        } label: {
                            if filter.categories.contains(category) {
                                Label(category, systemImage: "checkmark")
                            } else {
                                Text(category)
                            }
                        }
                    }
                    if !filter.categories.isEmpty {
                        Divider()
                        Button("Any category") { filter.categories = [] }
                    }
                } label: {
                    chip(filter.categories.isEmpty ? "Category" : filter.categories.count == 1 ? filter.categories.first! : "\(filter.categories.count) categories",
                         active: !filter.categories.isEmpty)
                }

                Menu {
                    Picker("Type", selection: $filter.kind) {
                        ForEach(ItemFilter.Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    chip(filter.kind == .all ? "Existing & requested" : filter.kind.rawValue, active: filter.kind != .all)
                }

                Menu {
                    ForEach(ItemCondition.allCases) { condition in
                        Button {
                            if filter.conditions.contains(condition) { filter.conditions.remove(condition) } else { filter.conditions.insert(condition) }
                        } label: {
                            if filter.conditions.contains(condition) {
                                Label(condition.label, systemImage: "checkmark")
                            } else {
                                Text(condition.label)
                            }
                        }
                    }
                    if !filter.conditions.isEmpty {
                        Divider()
                        Button("Any condition") { filter.conditions = [] }
                    }
                } label: {
                    chip(filter.conditions.isEmpty ? "Condition" : filter.conditions.count == 1 ? filter.conditions.first!.label : "\(filter.conditions.count) conditions",
                         active: !filter.conditions.isEmpty)
                }

                Button {
                    filter.aiOnly.toggle()
                } label: {
                    chip("Found by AI", active: filter.aiOnly)
                }

                if hasFilters {
                    Button("Clear") { filter = ItemFilter() }
                    .font(.footnote)
                }
            }
        }
    }

    private func chip(_ title: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: "chevron.down").font(.caption2)
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: Capsule())
        .foregroundStyle(active ? Color.white : Color.primary)
    }

    private var hasFilters: Bool {
        !filter.isEmpty
    }

    private var rooms: [Room] {
        guard let property = store.property(id: propertyID) else { return [] }
        if let roomID { return property.rooms.filter { $0.id == roomID } }
        return property.rooms
    }

    private var availableCategories: [String] {
        let used = Set(rooms.flatMap(\.items).map(\.category))
        return RoomItem.categories.filter(used.contains) + used.subtracting(RoomItem.categories).sorted()
    }

    private var filteredEntries: [Entry] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return rooms.flatMap { room in
            room.items.compactMap { item -> Entry? in
                if !filter.matches(item) { return nil }
                if !query.isEmpty,
                   !item.name.localizedCaseInsensitiveContains(query),
                   !item.notes.localizedCaseInsensitiveContains(query),
                   !item.category.localizedCaseInsensitiveContains(query) { return nil }
                return Entry(room: room, item: item)
            }
        }
    }

    private func groupedRooms(_ entries: [Entry]) -> [(room: Room, entries: [Entry])] {
        rooms.compactMap { room in
            let inRoom = entries.filter { $0.room.id == room.id }
            return inRoom.isEmpty ? nil : (room, inRoom)
        }
    }

    // MARK: Rows

    private func row(_ entry: Entry) -> some View {
        let item = entry.item
        return HStack(spacing: 12) {
            if let photo = ItemPhotos.image(named: item.photoFileName) {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Circle()
                    .fill(ItemColors.color(for: item))
                    .frame(width: 12, height: 12)
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.quantity > 1 ? "\(item.name) ×\(item.quantity)" : item.name)
                Text(details(for: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !item.notes.isEmpty {
                    Text(item.notes)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            Spacer()
            if item.detectedAutomatically {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
            }
        }
    }

    private func details(for entry: Entry) -> String {
        let item = entry.item
        var parts = [item.category, item.isRequested ? "Customer request" : item.condition.label]
        if let parent = entry.room.item(item.parentID) { parts.insert("On \(parent.name)", at: 0) }
        return parts.joined(separator: " · ")
    }

    // MARK: Changing many items

    private var bulkMenu: some View {
        Menu {
            Menu("Set Category") {
                ForEach(RoomItem.categories, id: \.self) { category in
                    Button(category) { changeSelected { $0.category = category } }
                }
            }
            Menu("Set Condition") {
                ForEach(ItemCondition.allCases) { condition in
                    Button(condition.label) { changeSelected { $0.condition = condition } }
                }
            }
            Button {
                changeSelected { $0.isRequested = true }
            } label: {
                Label("Mark as Customer Requests", systemImage: "cart.badge.plus")
            }
            Button {
                changeSelected { $0.isRequested = false }
            } label: {
                Label("Mark as Existing", systemImage: "house")
            }
            if roomID == nil || (store.property(id: propertyID)?.rooms.count ?? 0) > 1 {
                Menu("Move to Room") {
                    ForEach(store.property(id: propertyID)?.rooms ?? []) { room in
                        Button(room.name) { moveSelected(to: room.id) }
                    }
                }
            }
        } label: {
            Label("Edit", systemImage: "slider.horizontal.3")
        }
        .disabled(selection.isEmpty)
    }

    private func update(in roomID: Room.ID, _ change: (inout [RoomItem]) -> Void) {
        guard var room = store.room(roomID, in: propertyID) else { return }
        change(&room.items)
        store.update(room, in: propertyID)
    }

    private func changeSelected(_ change: (inout RoomItem) -> Void) {
        guard var property = store.property(id: propertyID) else { return }
        for r in property.rooms.indices {
            for i in property.rooms[r].items.indices where selection.contains(property.rooms[r].items[i].id) {
                change(&property.rooms[r].items[i])
            }
        }
        store.update(property)
    }

    private func deleteSelected() {
        delete(selection)
        selection = []
        editMode = .inactive
    }

    private func delete(_ ids: Set<UUID>) {
        guard var property = store.property(id: propertyID) else { return }
        for r in property.rooms.indices {
            for item in property.rooms[r].items where ids.contains(item.id) {
                ItemPhotos.delete(item.photoFileName)
            }
            property.rooms[r].items.removeAll { ids.contains($0.id) }
            // Whatever sat on a deleted item stays in the room on its own.
            for i in property.rooms[r].items.indices {
                if let parent = property.rooms[r].items[i].parentID, ids.contains(parent) {
                    property.rooms[r].items[i].parentID = nil
                }
            }
        }
        store.update(property)
    }

    /// Moves the selected items to another room. Their spots on the old plan no longer apply.
    private func moveSelected(to target: Room.ID) {
        guard var property = store.property(id: propertyID),
              let targetIndex = property.rooms.firstIndex(where: { $0.id == target }) else { return }
        var moving: [RoomItem] = []
        for r in property.rooms.indices where r != targetIndex {
            let picked = property.rooms[r].items.filter { selection.contains($0.id) }
            property.rooms[r].items.removeAll { selection.contains($0.id) }
            moving += picked.map { item in
                var item = item
                item.position = nil
                item.parentID = nil
                return item
            }
        }
        property.rooms[targetIndex].items += moving
        store.update(property)
        selection = []
    }
}
