import SwiftUI

/// A whole property: house floor plan, totals, and its rooms.
struct PropertyView: View {
    let propertyID: Property.ID
    let onAddRooms: (CaptureMode) -> Void

    @EnvironmentObject private var store: PropertyStore
    @AppStorage(Units.useFeetKey) private var useFeet = true
    @State private var showingAddRooms = false
    @State private var nextMode: CaptureMode?

    var body: some View {
        if let property = store.property(id: propertyID) {
            content(for: property)
        } else {
            ContentUnavailableView("Property deleted", systemImage: "trash")
        }
    }

    private func content(for property: Property) -> some View {
        List {
            if !property.rooms.isEmpty {
                Section {
                    FloorPlanView(rooms: property.rooms, showDetails: false, useFeet: useFeet)
                        .frame(height: 320)
                        .listRowInsets(EdgeInsets())
                }
            }

            Section("Summary") {
                if !property.address.isEmpty {
                    LabeledContent("Address", value: property.address)
                }
                LabeledContent("Rooms", value: "\(property.rooms.count)")
                LabeledContent("Total floor area", value: Units.area(property.totalArea, feet: useFeet))
                LabeledContent("Items documented", value: "\(property.itemCount)")
                LabeledContent("Customer requests", value: "\(property.requestedCount)")
            }

            Section("Rooms") {
                ForEach(property.rooms) { room in
                    NavigationLink {
                        RoomDetailView(propertyID: propertyID, roomID: room.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(room.name).font(.headline)
                            Text("\(Units.area(room.area, feet: useFeet)) · \(room.items.count) items")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        store.deleteRoom(property.rooms[index].id, in: propertyID)
                    }
                }
                .onMove { source, destination in
                    var updated = property
                    updated.rooms.move(fromOffsets: source, toOffset: destination)
                    store.update(updated)
                }

                Button {
                    showingAddRooms = true
                } label: {
                    Label("Add Rooms", systemImage: "plus")
                }
            }
        }
        .navigationTitle(property.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: PropertyReport.text(for: property, useFeet: useFeet)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                EditButton()
            }
        }
        .sheet(isPresented: $showingAddRooms, onDismiss: {
            if let mode = nextMode { onAddRooms(mode) }
            nextMode = nil
        }) {
            NavigationStack {
                Form {
                    Section {
                        Text("Rooms added later have their own measurements, but they are placed beside the existing plan rather than lined up with it. For a connected floor plan, map the whole property in one go.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    CaptureModeSection { mode in
                        nextMode = mode
                        showingAddRooms = false
                    }
                }
                .navigationTitle("Add Rooms")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium])
        }
    }
}

/// Plain-text summary of a property for sharing by text or email.
enum PropertyReport {
    static func text(for property: Property, useFeet: Bool) -> String {
        var lines = [property.name]
        if !property.address.isEmpty { lines.append(property.address) }
        lines.append("\(property.rooms.count) rooms · \(Units.area(property.totalArea, feet: useFeet)) total")
        for room in property.rooms {
            lines.append("")
            lines.append(String(repeating: "—", count: 12))
            lines.append(RoomReport.text(for: room, useFeet: useFeet))
        }
        return lines.joined(separator: "\n")
    }
}
