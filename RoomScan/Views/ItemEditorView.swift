import PhotosUI
import SwiftUI

struct ItemEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var item: RoomItem
    let isNew: Bool
    /// The room the item is in, for choosing what it sits on and listing what sits on it.
    let room: Room
    let onSave: (RoomItem) -> Void
    let onDelete: (() -> Void)?
    /// Saves this item, then opens another one (`true` when it is new) in its place.
    let onOpen: ((RoomItem, Bool) -> Void)?

    @State private var photo: UIImage?
    @State private var photoChanged = false
    @State private var takingPhoto = false
    @State private var libraryPick: PhotosPickerItem?

    init(item: RoomItem, isNew: Bool, room: Room, onSave: @escaping (RoomItem) -> Void,
         onDelete: (() -> Void)? = nil, onOpen: ((RoomItem, Bool) -> Void)? = nil) {
        _item = State(initialValue: item)
        _photo = State(initialValue: ItemPhotos.image(named: item.photoFileName))
        self.isNew = isNew
        self.room = room
        self.onSave = onSave
        self.onDelete = onDelete
        self.onOpen = onOpen
    }

    var body: some View {
        NavigationStack {
            Form {
                photoSection

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

                if !parentOptions.isEmpty || item.parentID != nil {
                    Section {
                        Picker("Sits on", selection: $item.parentID) {
                            Text("Nothing").tag(UUID?.none)
                            ForEach(parentOptions) { other in
                                Text(label(for: other)).tag(Optional(other.id))
                            }
                        }
                    } footer: {
                        Text("For things on top of or attached to another item, like a phone on a desk.")
                    }
                }

                stackedItemsSection

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
                        _ = commit()
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .onChange(of: item.parentID) {
                // Something placed on another item sits where that item is.
                if item.position == nil, let parent = room.item(item.parentID) {
                    item.position = parent.position
                }
            }
            .onChange(of: libraryPick) {
                guard let pick = libraryPick else { return }
                Task { @MainActor in
                    if let data = try? await pick.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        photo = ItemPhotos.resized(image)
                        photoChanged = true
                    }
                    libraryPick = nil
                }
            }
            .fullScreenCover(isPresented: $takingPhoto) {
                CameraPicker { image in
                    photo = ItemPhotos.resized(image)
                    photoChanged = true
                }
                .ignoresSafeArea()
            }
        }
    }

    private var photoSection: some View {
        Section {
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    takingPhoto = true
                } label: {
                    Label(photo == nil ? "Take Photo" : "Retake Photo", systemImage: "camera")
                }
            }
            PhotosPicker(selection: $libraryPick, matching: .images) {
                Label("Choose from Library", systemImage: "photo.on.rectangle")
            }
            if photo != nil {
                Button("Remove Photo", role: .destructive) {
                    photo = nil
                    photoChanged = true
                }
            }
        } header: {
            Text("Photo")
        } footer: {
            if item.detectedAutomatically, photo != nil, !photoChanged {
                Text("Cut from the photo the AI looked at, so you can see where the item is.")
            }
        }
    }

    @ViewBuilder
    private var stackedItemsSection: some View {
        if let onOpen {
            Section {
                ForEach(room.items(on: item)) { child in
                    Button {
                        _ = commit()
                        onOpen(child, false)
                        dismiss()
                    } label: {
                        LabeledContent(label(for: child), value: child.isRequested ? "Requested" : child.category)
                    }
                    .foregroundStyle(.primary)
                    .disabled(!canSave)
                }
                Button {
                    addOnTop(requested: false)
                } label: {
                    Label("Add Item on Top", systemImage: "square.stack.3d.up")
                }
                .disabled(!canSave)
                Button {
                    addOnTop(requested: true)
                } label: {
                    Label("Add Requested Item on Top", systemImage: "cart.badge.plus")
                }
                .disabled(!canSave)
            } header: {
                Text(item.name.isEmpty ? "On this item" : "On this \(item.name)")
            } footer: {
                Text("Adds an item that sits on or belongs with this one. It is pinned at the same spot on the plan.")
            }
        }
    }

    private func addOnTop(requested: Bool) {
        let saved = commit()
        onOpen?(RoomItem(name: "", isRequested: requested, position: saved.position, parentID: saved.id), true)
        dismiss()
    }

    private var canSave: Bool {
        !item.name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Saves the item, including a new or removed photo, and returns what was saved.
    private func commit() -> RoomItem {
        var saved = item
        if photoChanged {
            ItemPhotos.delete(item.photoFileName)
            saved.photoFileName = photo.flatMap { ItemPhotos.save($0) }
            item.photoFileName = saved.photoFileName
            photoChanged = false
        }
        onSave(saved)
        return saved
    }

    /// Items this one can sit on: anything in the room except itself and what sits on it.
    private var parentOptions: [RoomItem] {
        let excluded = room.itemAndEverythingOn(item)
        return room.items.filter { !excluded.contains($0.id) }
    }

    /// Numbered like the pins on the plan, so three outlets can be told apart.
    private func label(for other: RoomItem) -> String {
        guard let index = room.items.firstIndex(where: { $0.id == other.id }) else { return other.name }
        return "\(index + 1). \(other.name)"
    }

    /// Preset categories, plus the item's own if a scan gave it one that is not in the list.
    private var categoryOptions: [String] {
        RoomItem.categories.contains(item.category) ? RoomItem.categories : RoomItem.categories + [item.category]
    }
}

/// The iPhone camera, for photographing an item.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
