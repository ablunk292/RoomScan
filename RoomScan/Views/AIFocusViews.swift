import SwiftUI

/// Chooses what AI Find Items looks for: everything, a saved preset, or a description typed
/// for this walkthrough.
struct AIFocusPicker: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DetectionPresets.shared
    @State private var customText = ""
    @State private var namingPreset = false
    @State private var presetName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    choiceRow("Everything", detail: "Every item worth documenting", focus: "")
                    ForEach(store.presets) { preset in
                        choiceRow(preset.name, detail: preset.focus, focus: preset.focus)
                    }
                } header: {
                    Text("Look for")
                }

                Section {
                    TextField("Main furniture, IT equipment and electrical…", text: $customText, axis: .vertical)
                        .lineLimit(2...5)
                    Button("Look for This") {
                        store.activeFocus = trimmedCustom
                        dismiss()
                    }
                    .disabled(trimmedCustom.isEmpty)
                    Button("Save as Preset") {
                        presetName = ""
                        namingPreset = true
                    }
                    .disabled(trimmedCustom.isEmpty)
                } header: {
                    Text("Or describe it")
                } footer: {
                    Text("Write it the way you would tell a helper, for example \"windows, doors and door handles\". The AI will only pick up those things.")
                }

                Section {
                    NavigationLink("Edit Presets") { PresetListView() }
                }
            }
            .navigationTitle("AI Find Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if !store.presets.contains(where: { $0.focus == store.activeFocus }) {
                    customText = store.activeFocus
                }
            }
            .alert("Name this preset", isPresented: $namingPreset) {
                TextField("Preset name", text: $presetName)
                Button("Save") {
                    let name = presetName.trimmingCharacters(in: .whitespaces)
                    let preset = DetectionPreset(name: name.isEmpty ? trimmedCustom : name, focus: trimmedCustom)
                    store.presets.append(preset)
                    store.activeFocus = preset.focus
                    customText = ""
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var trimmedCustom: String {
        customText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func choiceRow(_ name: String, detail: String, focus: String) -> some View {
        Button {
            store.activeFocus = focus
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if store.activeFocus == focus {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
    }
}

/// Add, change, reorder and delete the presets for AI Find Items.
struct PresetListView: View {
    @ObservedObject private var store = DetectionPresets.shared
    @State private var editing: DetectionPreset?

    var body: some View {
        List {
            Section {
                ForEach(store.presets) { preset in
                    Button {
                        editing = preset
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name).foregroundStyle(.primary)
                            Text(preset.focus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .onDelete { store.presets.remove(atOffsets: $0) }
                .onMove { store.presets.move(fromOffsets: $0, toOffset: $1) }

                Button {
                    editing = DetectionPreset(name: "", focus: "")
                } label: {
                    Label("New Preset", systemImage: "plus")
                }
            } footer: {
                Text("Presets are quick choices for what AI Find Items picks up, like \"Windows and doors\" for a window job.")
            }

            Section {
                Button("Add Starter Presets Back") {
                    let existing = Set(store.presets.map(\.name))
                    store.presets += DetectionPresets.starters.filter { !existing.contains($0.name) }
                }
            }
        }
        .navigationTitle("AI Presets")
        .toolbar { EditButton() }
        .sheet(item: $editing) { preset in
            PresetEditor(preset: preset) { saved in
                if let index = store.presets.firstIndex(where: { $0.id == saved.id }) {
                    // Keep the active choice pointing at this preset if it was in use.
                    if store.activeFocus == store.presets[index].focus { store.activeFocus = saved.focus }
                    store.presets[index] = saved
                } else {
                    store.presets.append(saved)
                }
            }
        }
    }
}

private struct PresetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var preset: DetectionPreset
    let onSave: (DetectionPreset) -> Void

    init(preset: DetectionPreset, onSave: @escaping (DetectionPreset) -> Void) {
        _preset = State(initialValue: preset)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Windows and doors", text: $preset.name)
                }
                Section {
                    TextField("Windows, doors, door handles, locks…", text: $preset.focus, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("What the AI looks for")
                } footer: {
                    Text("List the kinds of things to pick up. Everything else is left out.")
                }
            }
            .navigationTitle(preset.name.isEmpty ? "New Preset" : preset.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        preset.name = preset.name.trimmingCharacters(in: .whitespaces)
                        preset.focus = preset.focus.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(preset)
                        dismiss()
                    }
                    .disabled(preset.name.trimmingCharacters(in: .whitespaces).isEmpty
                              || preset.focus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// Small button showing what AI Find Items is set to look for; opens the picker.
struct AIFocusButton: View {
    @ObservedObject private var store = DetectionPresets.shared
    @State private var choosing = false

    var body: some View {
        Button {
            choosing = true
        } label: {
            Label("AI looks for: \(store.activeName)", systemImage: "line.3.horizontal.decrease.circle")
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .foregroundStyle(.primary)
        .sheet(isPresented: $choosing) {
            AIFocusPicker()
        }
    }
}
