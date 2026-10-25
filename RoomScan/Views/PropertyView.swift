import SwiftUI

/// A whole property: house floor plan, totals, and its rooms.
struct PropertyView: View {
    let propertyID: Property.ID
    let onAddRooms: (CaptureMode) -> Void

    @EnvironmentObject private var store: PropertyStore
    @AppStorage(Units.useFeetKey) private var useFeet = true
    @State private var showingAddRooms = false
    @State private var arranging = false
    /// Room opened by tapping it on the house plan.
    @State private var openRoom: Room.ID?
    @State private var nextMode: CaptureMode?
    @State private var sharing: SharePayload?
    @State private var editingDetails = false
    @State private var exportError: String?
    @State private var choosingExport = false
    /// Files made in the export sheet, shared once that sheet has closed.
    @State private var pendingShare: SharePayload?

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
                    FloorPlanView(
                        rooms: property.rooms,
                        showDetails: false,
                        useFeet: useFeet,
                        onTapItem: { roomID, _ in openRoom = roomID },
                        onTapLocation: { point in
                            openRoom = property.rooms.last(where: { Geometry.contains($0.outline, point) })?.id
                        }
                    )
                        .frame(height: 320)
                        .listRowInsets(EdgeInsets())
                    if property.rooms.count > 1 {
                        Button {
                            arranging = true
                        } label: {
                            Label("Arrange Rooms", systemImage: "hand.draw")
                        }
                    }
                }
            }

            Section {
                if !property.address.isEmpty {
                    LabeledContent("Address", value: property.address)
                }
                if let customer = property.customerName, !customer.isEmpty {
                    LabeledContent("Customer", value: customer)
                }
                LabeledContent("Rooms", value: "\(property.rooms.count)")
                LabeledContent("Total floor area", value: Units.area(property.totalArea, feet: useFeet))
                LabeledContent("Items documented", value: "\(property.itemCount)")
                LabeledContent("Customer requests", value: "\(property.requestedCount)")
            } header: {
                HStack {
                    Text("Summary")
                    Spacer()
                    Button("Edit") { editingDetails = true }
                        .font(.caption)
                }
            }

            Section {
                Button {
                    choosingExport = true
                } label: {
                    Label("Export Findings", systemImage: "square.and.arrow.up.on.square")
                }
            } footer: {
                Text("Choose the rooms and findings to include. Creates a PDF report with floor plans and photos, a spreadsheet of the items, and a data file for quoting tools such as QuoteMaster.")
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
                Menu {
                    Button {
                        choosingExport = true
                    } label: {
                        Label("Export Findings", systemImage: "doc.richtext")
                    }
                    ShareLink(item: PropertyReport.text(for: property, useFeet: useFeet)) {
                        Label("Share Text Summary", systemImage: "text.alignleft")
                    }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                EditButton()
            }
        }
        .navigationDestination(item: $openRoom) { roomID in
            RoomDetailView(propertyID: propertyID, roomID: roomID)
        }
        .sheet(isPresented: $choosingExport, onDismiss: {
            sharing = pendingShare
            pendingShare = nil
        }) {
            ExportOptionsView(property: property) { chosen, options in
                export(chosen, options: options)
            }
        }
        .sheet(item: $sharing) { payload in
            ShareSheet(items: payload.urls)
        }
        .sheet(isPresented: $editingDetails) {
            PropertyDetailsEditor(property: property) { store.update($0) }
        }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .fullScreenCover(isPresented: $arranging) {
            ArrangeRoomsView(propertyID: propertyID)
        }
        .sheet(isPresented: $showingAddRooms, onDismiss: {
            if let mode = nextMode { onAddRooms(mode) }
            nextMode = nil
        }) {
            NavigationStack {
                Form {
                    Section {
                        Text("Rooms added later are placed beside the existing plan. Use Arrange Rooms afterwards to drag them into place; they snap to neighboring walls.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    AIFocusSection()
                    CaptureModeSection { mode in
                        nextMode = mode
                        showingAddRooms = false
                    }
                }
                .navigationTitle("Add Rooms")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
    }
}

extension PropertyView {
    private func export(_ property: Property, options: ExportFiles.Options) {
        do {
            pendingShare = SharePayload(urls: try ExportFiles.make(for: property, useFeet: useFeet, options: options))
        } catch {
            exportError = error.localizedDescription
        }
    }
}

/// Name, address and customer details for a property.
struct PropertyDetailsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var property: Property
    let onSave: (Property) -> Void

    init(property: Property, onSave: @escaping (Property) -> Void) {
        _property = State(initialValue: property)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Property") {
                    TextField("Name", text: $property.name)
                    TextField("Address", text: $property.address)
                }
                Section("Customer") {
                    TextField("Name", text: optional(\.customerName))
                    TextField("Email", text: optional(\.customerEmail))
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                    TextField("Phone", text: optional(\.customerPhone))
                        .keyboardType(.phonePad)
                }
                Section("Notes") {
                    TextField("Access, timing, budget…", text: $property.notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(property)
                        dismiss()
                    }
                    .disabled(property.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func optional(_ keyPath: WritableKeyPath<Property, String?>) -> Binding<String> {
        Binding(
            get: { property[keyPath: keyPath] ?? "" },
            set: { property[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
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
