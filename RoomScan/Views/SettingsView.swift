import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Units.useFeetKey) private var useFeet = true
    @State private var keyText = ""
    @State private var hasKey = APIKeyStore.hasKey
    @State private var showingWelcome = false

    var body: some View {
        NavigationStack {
            Form {
                AccountSection()

                Section("Help") {
                    Button {
                        showingWelcome = true
                    } label: {
                        Label("Show Tutorial", systemImage: "questionmark.circle")
                    }
                    NavigationLink {
                        ScanHelpView()
                    } label: {
                        Label("How to Scan a Room", systemImage: "ruler")
                    }
                }

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
                    NavigationLink("AI Presets") { PresetListView() }
                } header: {
                    Text("AI item detection")
                } footer: {
                    Text("Presets choose what the AI looks for, like only electrical or only doors and windows.")
                }

                #if DEBUG
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
                    Text("Developer: Claude API key")
                } footer: {
                    Text("Only in test builds. Used for AI scans when you are not signed in. Customers sign in instead and never see this.")
                }
                #endif
            }
            .fullScreenCover(isPresented: $showingWelcome) {
                WelcomeView()
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
