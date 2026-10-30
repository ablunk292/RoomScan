import SwiftUI

/// Lets the user pick which rooms and findings go into an export, and which files to make.
struct ExportOptionsView: View {
    let property: Property
    let onExport: (Property, ExportFiles.Options) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedRooms: Set<Room.ID>
    @State private var existing = ExistingItems.all
    @State private var requested = true
    @State private var options = ExportFiles.Options()

    enum ExistingItems: String, CaseIterable, Identifiable {
        case all = "All"
        case needingWork = "Needing work"
        case excluded = "None"

        var id: Self { self }
    }

    init(property: Property, onExport: @escaping (Property, ExportFiles.Options) -> Void) {
        self.property = property
        self.onExport = onExport
        _selectedRooms = State(initialValue: Set(property.rooms.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(property.rooms) { room in
                        Toggle(isOn: binding(for: room.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(room.name)
                                Text("\(room.items.count) items")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Rooms")
                        Spacer()
                        Button(selectedRooms.count == property.rooms.count ? "None" : "All") {
                            selectedRooms = selectedRooms.count == property.rooms.count ? [] : Set(property.rooms.map(\.id))
                        }
                        .font(.caption)
                    }
                }

                Section {
                    Picker("Existing items", selection: $existing) {
                        ForEach(ExistingItems.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Customer requested items", isOn: $requested)
                    Toggle("Item photos in the PDF", isOn: $options.photos)
                        .disabled(!options.pdf)
                } header: {
                    Text("Findings")
                } footer: {
                    Text("Needing work keeps only existing items marked as needing repair or replacement, or outdated.")
                }

                Section("Files") {
                    Toggle("PDF report", isOn: $options.pdf)
                    Toggle("Spreadsheet (CSV)", isOn: $options.spreadsheet)
                    Toggle("Quote data for QuoteMaster (JSON)", isOn: $options.quoteData)
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") {
                        onExport(filtered, options)
                        dismiss()
                    }
                    .disabled(selectedRooms.isEmpty || !(options.pdf || options.spreadsheet || options.quoteData))
                }
            }
        }
    }

    /// The property with only the chosen rooms and findings.
    private var filtered: Property {
        var result = property
        result.rooms = property.rooms.filter { selectedRooms.contains($0.id) }.map { room in
            var room = room
            room.items = room.items.filter { item in
                if item.isRequested { return requested }
                switch existing {
                case .all: return true
                case .needingWork: return item.condition != .good
                case .excluded: return false
                }
            }
            return room
        }
        return result
    }

    private func binding(for id: Room.ID) -> Binding<Bool> {
        Binding(
            get: { selectedRooms.contains(id) },
            set: { isOn in
                if isOn { selectedRooms.insert(id) } else { selectedRooms.remove(id) }
            }
        )
    }
}
