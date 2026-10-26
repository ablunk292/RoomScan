import SwiftUI

/// Writes down what the customer asks for while the room is being scanned, without stopping
/// the scan. Requests go on the quote. Several can be added in a row; the keyboard's mic
/// button dictates.
struct ClientRequestSheet: View {
    @ObservedObject var controller: CornerMeasureController
    let roomName: String

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var category = "Other"
    @State private var quantity = 1
    @State private var notes = ""
    @State private var pin = true
    @FocusState private var nameFocused: Bool

    private var requests: [RoomItem] { controller.items.filter(\.isRequested) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What do they want? TV mount, 2 outlets…", text: $name)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit(add)
                    Picker("Category", selection: $category) {
                        ForEach(RoomItem.categories, id: \.self) { Text($0) }
                    }
                    Stepper("Quantity: \(quantity)", value: $quantity, in: 1...99)
                    TextField("Notes, like where or which brand", text: $notes, axis: .vertical)
                    if controller.canPinRequest {
                        Toggle("Pin where the + points", isOn: $pin)
                    }
                } footer: {
                    Text("Tap the mic on the keyboard to say it instead of typing.")
                }

                Section {
                    Button(action: add) {
                        Label("Add Request", systemImage: "cart.badge.plus")
                            .font(.headline)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if !requests.isEmpty {
                    Section("Requested in \(roomName)") {
                        ForEach(requests) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.quantity > 1 ? "\(item.name) ×\(item.quantity)" : item.name)
                                Text([item.category, item.notes].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { requests[$0].id }.forEach(controller.removeItem)
                        }
                    }
                }
            }
            .navigationTitle("Client Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { nameFocused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func add() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        controller.addRequest(RoomItem(name: trimmed, category: category, quantity: quantity,
                                       notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)),
                              pinned: pin)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        name = ""
        notes = ""
        quantity = 1
        nameFocused = true
    }
}
