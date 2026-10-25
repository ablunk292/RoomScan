import SwiftUI

struct ItemEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var item: RoomItem
    let isNew: Bool
    let onSave: (RoomItem) -> Void
    let onDelete: (() -> Void)?

    init(item: RoomItem, isNew: Bool, onSave: @escaping (RoomItem) -> Void, onDelete: (() -> Void)? = nil) {
        _item = State(initialValue: item)
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $item.name)
                    Picker("Category", selection: $item.category) {
                        ForEach(categoryOptions, id: \.self) { Text($0).tag($0) }
                    }
                    Stepper("Quantity: \(item.quantity)", value: $item.quantity, in: 1...999)
                }

                Section {
                    Toggle("Customer requested", isOn: $item.isRequested)
                    if !item.isRequested {
                        Picker("Condition", selection: $item.condition) {
                            ForEach(ItemCondition.allCases) { Text($0.label).tag($0) }
                        }
                    }
                } footer: {
                    Text(item.isRequested
                         ? "Requested items are things the customer wants added. They go on the quote."
                         : "Existing items are already in the room.")
                }

                Section("Notes") {
                    TextField("Model, location, details…", text: $item.notes, axis: .vertical)
                        .lineLimit(3...8)
                }

                if let size = item.dimensions {
                    Section("Measured size") {
                        LabeledContent("Width", value: Units.length(size.width))
                        LabeledContent("Depth", value: Units.length(size.depth))
                        LabeledContent("Height", value: Units.length(size.height))
                    }
                }

                if let onDelete {
                    Section {
                        Button("Delete Item", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New Item" : "Edit Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(item)
                        dismiss()
                    }
                    .disabled(item.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    /// Preset categories, plus the item's own if a scan gave it one that is not in the list.
    private var categoryOptions: [String] {
        RoomItem.categories.contains(item.category) ? RoomItem.categories : RoomItem.categories + [item.category]
    }
}
