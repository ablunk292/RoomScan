import SwiftUI

/// Sign in with a QuoteMaster account, which syncs walkthroughs to the web editor and runs the AI
/// on the RoomScan server.
struct AccountSection: View {
    @ObservedObject private var sync = CloudSync.shared
    @State private var signingIn = false

    var body: some View {
        Section {
            if sync.isSignedIn {
                LabeledContent("Signed in as", value: sync.email)
                LabeledContent("Last synced") {
                    if sync.isSyncing {
                        ProgressView()
                    } else {
                        Text(sync.lastSynced.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not yet")
                    }
                }
                if let error = sync.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                Button {
                    Task { await sync.sync() }
                } label: {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(sync.isSyncing)
                Link(destination: CloudConfig.webApp) {
                    Label("Open RoomScan on the Web", systemImage: "safari")
                }
                Button("Sign Out", role: .destructive) { sync.signOut() }
            } else {
                Button {
                    signingIn = true
                } label: {
                    Label("Sign In with QuoteMaster", systemImage: "person.crop.circle")
                }
            }
        } header: {
            Text("Account")
        } footer: {
            Text(sync.isSignedIn
                 ? "Walkthroughs sync to your company's account. Edit them on a computer at \(CloudConfig.webApp.host ?? "the web") and send them to QuoteMaster."
                 : "Sign in to use AI item detection, back up your walkthroughs, edit them on a computer and send them to QuoteMaster. Walkthroughs stay on this phone either way.")
        }
        .sheet(isPresented: $signingIn) { SignInView() }
    }
}

struct SignInView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var resetSent = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } footer: {
                    Text("Use the same email and password as QuoteMaster.")
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
                if resetSent {
                    Text("Check your email for a link to reset your password.").foregroundStyle(.green)
                }
                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            Text("Sign In").font(.headline)
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || email.isEmpty || password.isEmpty)
                    Button("Forgot Password?") {
                        Task {
                            do {
                                try await CloudAuthAPI.resetPassword(email: email)
                                resetSent = true
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                    .disabled(email.isEmpty)
                }
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func signIn() async {
        busy = true
        error = nil
        do {
            try await CloudSync.shared.signIn(email: email, password: password)
            dismiss()
        } catch CloudError.http(let status, _) where status == 400 {
            error = "That email and password didn't match a QuoteMaster account."
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}
