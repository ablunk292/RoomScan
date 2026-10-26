import Foundation
import SwiftUI

/// Keeps walkthroughs on this phone in step with the cloud, so they show up in the RoomScan web
/// editor and on the user's other devices. Each walkthrough is one row holding its whole JSON;
/// `version` goes up on every save, which is how a change made elsewhere is noticed.
///
/// If the same walkthrough changed both here and elsewhere since the last sync, the cloud copy
/// wins and this phone's copy is kept as a separate walkthrough named "(phone copy)", so nothing
/// is lost.
@MainActor
final class CloudSync: ObservableObject {
    static let shared = CloudSync()

    @Published private(set) var isSignedIn = SessionStore.isSignedIn
    @Published private(set) var email = SessionStore.load()?.email ?? ""
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSynced: Date?
    @Published private(set) var lastError: String?

    private struct Entry: Codable {
        /// The cloud version this phone last saw, or nil if it was never uploaded.
        var version: Int?
        var dirty = false
        var deleted = false
        var uploadedPhotos: Set<String> = []
    }

    private var state: [UUID: Entry] = [:]
    private weak var store: PropertyStore?
    private var pending: Task<Void, Never>?
    private let stateURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("sync-state.json")

    private init() {
        if let data = try? Data(contentsOf: stateURL),
           let saved = try? JSONDecoder().decode([UUID: Entry].self, from: data) {
            state = saved
        }
        if let date = UserDefaults.standard.object(forKey: "cloud.lastSynced") as? Date { lastSynced = date }
    }

    func attach(_ store: PropertyStore) {
        self.store = store
        store.onLocalChange = { [weak self] id in self?.markChanged(id) }
        store.onLocalDelete = { [weak self] id in self?.markDeleted(id) }
        scheduleSync(after: 1)
    }

    // MARK: Account

    func signIn(email: String, password: String) async throws {
        let session = try await CloudAuthAPI.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
        await signedIn(session)
    }

    /// Signs in with Google or Microsoft in a browser sheet. `authenticate` is SwiftUI's
    /// web authentication session, which returns the URL the browser came back with.
    func signIn(provider: String, authenticate: (URL, String) async throws -> URL) async throws {
        let start = CloudAuthAPI.providerSignIn(provider)
        let callback = try await authenticate(start.url, CloudAuthAPI.callbackScheme)
        let session = try await CloudAuthAPI.finishProviderSignIn(callback: callback, verifier: start.verifier)
        await signedIn(session)
    }

    private func signedIn(_ session: CloudSession) async {
        SessionStore.save(session)
        CloudAPI.forgetTenant()
        isSignedIn = true
        self.email = session.email
        // Everything on the phone is new to this account.
        if let store {
            for property in store.properties where state[property.id]?.version == nil {
                state[property.id, default: Entry()].dirty = true
            }
            saveState()
        }
        await sync()
    }

    func signOut() {
        SessionStore.delete()
        CloudAPI.forgetTenant()
        isSignedIn = false
        email = ""
        lastError = nil
        // A different account later starts fresh; the walkthroughs stay on the phone.
        state = [:]
        saveState()
    }

    // MARK: Changes on this phone

    private func markChanged(_ id: UUID) {
        state[id, default: Entry()].dirty = true
        saveState()
        scheduleSync()
    }

    private func markDeleted(_ id: UUID) {
        if state[id]?.version == nil {
            state[id] = nil
        } else {
            state[id]?.deleted = true
        }
        saveState()
        scheduleSync()
    }

    /// Syncs a few seconds after the last change, so a burst of edits is one upload.
    func scheduleSync(after seconds: Double = 4) {
        guard isSignedIn else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    // MARK: Sync

    private struct RemoteRow: Decodable {
        var id: UUID
        var version: Int
        var deleted_at: String?
    }

    func sync() async {
        guard isSignedIn, let store, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let list = try await CloudAPI.request("rest/v1/roomscan_property", query: [
                URLQueryItem(name: "select", value: "id,version,deleted_at"),
            ])
            let remote = Dictionary(uniqueKeysWithValues: try JSONDecoder().decode([RemoteRow].self, from: list).map { ($0.id, $0) })

            // Deleted here.
            for (id, entry) in state where entry.deleted {
                if let row = remote[id], row.deleted_at == nil {
                    _ = try await CloudAPI.request("rest/v1/roomscan_property", method: "PATCH",
                                                   query: [URLQueryItem(name: "id", value: "eq.\(id.uuidString)")],
                                                   json: ["deleted_at": ISO8601DateFormatter().string(from: Date())])
                }
                state[id] = nil
            }

            // On this phone.
            for property in store.properties {
                let entry = state[property.id] ?? Entry()
                guard let row = remote[property.id] else {
                    if entry.version != nil && !entry.dirty {
                        store.removeFromCloud(property.id)   // removed for good elsewhere
                        state[property.id] = nil
                    } else {
                        try await insert(property)
                    }
                    continue
                }
                if row.deleted_at != nil {
                    if entry.dirty {
                        try await overwrite(property, restoring: true)
                    } else {
                        store.removeFromCloud(property.id)
                        state[property.id] = nil
                    }
                } else if row.version == entry.version {
                    if entry.dirty {
                        let saved = try await upload(property, expecting: row.version)
                        if !saved { try await resolveConflict(property) }
                    }
                } else if entry.dirty {
                    try await resolveConflict(property)
                } else {
                    try await download(property.id)
                }
            }

            // Only in the cloud.
            let local = Set(store.properties.map(\.id))
            for row in remote.values where row.deleted_at == nil && !local.contains(row.id) {
                try await download(row.id)
            }

            try await syncPhotos()
            lastSynced = Date()
            UserDefaults.standard.set(lastSynced, forKey: "cloud.lastSynced")
            lastError = nil
        } catch CloudError.notSignedIn {
            signOut()
            lastError = "Signed out. Sign in again in Settings to keep syncing."
        } catch {
            lastError = error.localizedDescription
        }
        saveState()
    }

    private func row(for property: Property) throws -> [String: Any] {
        let data = try JSONEncoder().encode(property)
        return ["id": property.id.uuidString, "name": property.name, "data": try JSONSerialization.jsonObject(with: data)]
    }

    private func insert(_ property: Property) async throws {
        let data = try await CloudAPI.request("rest/v1/roomscan_property", method: "POST", json: try row(for: property),
                                              headers: ["Prefer": "return=representation"])
        state[property.id, default: Entry()].version = try versions(in: data).first
        state[property.id]?.dirty = false
    }

    /// Saves over the cloud copy only if it is still the version this phone last saw.
    private func upload(_ property: Property, expecting version: Int) async throws -> Bool {
        var fields = try row(for: property)
        fields["id"] = nil
        let data = try await CloudAPI.request("rest/v1/roomscan_property", method: "PATCH", query: [
            URLQueryItem(name: "id", value: "eq.\(property.id.uuidString)"),
            URLQueryItem(name: "version", value: "eq.\(version)"),
        ], json: fields, headers: ["Prefer": "return=representation"])
        guard let newVersion = try versions(in: data).first else { return false }
        state[property.id]?.version = newVersion
        state[property.id]?.dirty = false
        return true
    }

    private func overwrite(_ property: Property, restoring: Bool) async throws {
        var fields = try row(for: property)
        fields["id"] = nil
        if restoring { fields["deleted_at"] = NSNull() }
        let data = try await CloudAPI.request("rest/v1/roomscan_property", method: "PATCH",
                                              query: [URLQueryItem(name: "id", value: "eq.\(property.id.uuidString)")],
                                              json: fields, headers: ["Prefer": "return=representation"])
        state[property.id, default: Entry()].version = try versions(in: data).first
        state[property.id]?.dirty = false
    }

    private func download(_ id: UUID) async throws {
        let data = try await CloudAPI.request("rest/v1/roomscan_property", query: [
            URLQueryItem(name: "select", value: "data,version"),
            URLQueryItem(name: "id", value: "eq.\(id.uuidString)"),
        ])
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = rows.first, let json = first["data"], let version = first["version"] as? Int else { return }
        do {
            let property = try JSONDecoder().decode(Property.self, from: try JSONSerialization.data(withJSONObject: json))
            store?.applyFromCloud(property)
            state[id, default: Entry()].version = version
            state[id]?.dirty = false
        } catch {
            // A copy this version of the app can't read; leave it in the cloud untouched.
            print("CloudSync: could not read walkthrough \(id): \(error)")
        }
    }

    /// Both sides changed: keep the cloud copy, and save this phone's edits as a separate walkthrough.
    private func resolveConflict(_ property: Property) async throws {
        var copy = property
        copy.id = UUID()
        copy.name = property.name + " (phone copy)"
        try await download(property.id)
        store?.add(copy)   // marks the copy as changed, so it uploads on the next sync
        state[copy.id, default: Entry()].uploadedPhotos = []
        lastError = "\(property.name) was changed on another device too. Your phone's edits were kept as \"\(copy.name)\"."
    }

    private func versions(in data: Data) throws -> [Int] {
        let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return rows.compactMap { $0["version"] as? Int }
    }

    // MARK: Photos

    /// Uploads item photos the cloud doesn't have yet, and downloads ones added elsewhere.
    private func syncPhotos() async throws {
        guard let store else { return }
        let tenant = try await CloudAPI.tenantID()
        for property in store.properties {
            guard state[property.id]?.version != nil else { continue }
            let names = Set(property.rooms.flatMap { $0.items.compactMap(\.photoFileName) })
            for name in names {
                let path = "storage/v1/object/\(CloudConfig.photoBucket)/\(tenant)/\(property.id.uuidString)/\(name)"
                let local = ItemPhotos.directory.appendingPathComponent(name)
                if let jpeg = try? Data(contentsOf: local) {
                    guard state[property.id]?.uploadedPhotos.contains(name) != true else { continue }
                    _ = try await CloudAPI.request(path, method: "POST", body: jpeg, contentType: "image/jpeg",
                                                   headers: ["x-upsert": "true"])
                    state[property.id]?.uploadedPhotos.insert(name)
                } else {
                    let authenticated = "storage/v1/object/authenticated/\(CloudConfig.photoBucket)/\(tenant)/\(property.id.uuidString)/\(name)"
                    if let data = try? await CloudAPI.request(authenticated) {
                        try? data.write(to: local, options: .atomic)
                        state[property.id]?.uploadedPhotos.insert(name)
                    }
                }
            }
        }
    }

    private func saveState() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    /// Opens this walkthrough on the web, optionally straight into the QuoteMaster wizard.
    func webURL(for property: Property, quote: Bool = false) -> URL {
        var url = CloudConfig.webApp.appendingPathComponent("w/\(property.id.uuidString)")
        if quote { url = URL(string: url.absoluteString + "?quote=1")! }
        return url
    }

    func isUploaded(_ id: UUID) -> Bool { state[id]?.version != nil && state[id]?.dirty == false }
}
