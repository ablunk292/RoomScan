import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Units.useFeetKey) private var useFeet = true
    @State private var keyText = ""
    @State private var hasKey = APIKeyStore.hasKey

    var body: some View {
        NavigationStack {
            Form {
                Section("Units") {
                    Picker("Measure in", selection: $useFeet) {
                        Text("Feet and inches").tag(true)
                        Text("Meters").tag(false)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    LabeledContent("LiDAR scanning", value: LiDARSupport.isAvailable ? "Available" : "Not available")
                } header: {
                    Text("This iPhone")
                } footer: {
                    if !LiDARSupport.isAvailable {
                        Text(LiDARSupport.explanation)
                    }
                }

                Section {
                    if hasKey {
                        LabeledContent("Claude API key", value: "Saved")
                        Button("Remove Key", role: .destructive) {
                            APIKeyStore.delete()
                            hasKey = false
                        }
                    } else {
                        SecureField("Paste your key (sk-ant-…)", text: $keyText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Save Key") {
                            APIKeyStore.save(keyText)
                            keyText = ""
                            hasKey = APIKeyStore.hasKey
                        }
                        .disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("AI item detection")
                } footer: {
                    Text("Used by AI Find Items to recognize what is in a room. Create a key at console.anthropic.com under API Keys. It is stored in this iPhone's Keychain. Each photo costs a few cents.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
