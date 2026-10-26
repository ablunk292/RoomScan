import RoomPlan
import SwiftUI

enum CaptureMode: String, Identifiable {
    case cornerTap
    case lidar

    var id: String { rawValue }
}

/// What a capture session is for: a brand-new property, or more rooms for an existing one.
struct CaptureRequest: Identifiable {
    enum Target {
        case newProperty(name: String, address: String, customer: String)
        case existing(Property.ID)
    }

    let id = UUID()
    let mode: CaptureMode
    let target: Target
    let firstRoomName: String
}

struct HomeView: View {
    @EnvironmentObject private var store: PropertyStore
    @ObservedObject private var sync = CloudSync.shared
    @AppStorage(Units.useFeetKey) private var useFeet = true
    @State private var path: [Property.ID] = []
    @State private var showingNewProperty = false
    @State private var showingSettings = false
    @State private var showingSignIn = false
    @State private var capture: CaptureRequest?
    /// Chosen in the New Property sheet; opened once the sheet has finished closing,
    /// since SwiftUI cannot present a full-screen view while a sheet is dismissing.
    @State private var nextCapture: CaptureRequest?
    @AppStorage("lidarNoticeShown") private var lidarNoticeShown = false
    @State private var showingLiDARNotice = false
    @AppStorage("welcomeShown") private var welcomeShown = false
    @State private var showingWelcome = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !sync.isSignedIn {
                    Button {
                        showingSignIn = true
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sign in with QuoteMaster").font(.headline)
                                Text("Turns on AI item detection, backup, the web editor and quoting.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "person.crop.circle.badge.plus")
                        }
                    }
                } else if let error = sync.lastError {
                    Label(error, systemImage: "exclamationmark.icloud")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if store.properties.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "house.and.flag")
                            .font(.system(size: 48))
                            .foregroundStyle(.tint)
                        Text("Start your first walkthrough")
                            .font(.title3.bold())
                        Text("Map each room of a house, apartment or building, and let AI document what is inside.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button {
                            showingNewProperty = true
                        } label: {
                            Label("Start a Walkthrough", systemImage: "plus")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        Button("How it works") { showingWelcome = true }
                    }
                    .padding(.vertical, 32)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                ForEach(store.properties) { property in
                    NavigationLink(value: property.id) {
                        PropertyRow(property: property, useFeet: useFeet)
                    }
                }
                .onDelete { store.delete(at: $0) }
            }
            .navigationTitle("RoomScan")
            .refreshable { await sync.sync() }
            .navigationDestination(for: Property.ID.self) { id in
                PropertyView(propertyID: id) { mode in
                    capture = CaptureRequest(mode: mode, target: .existing(id), firstRoomName: "Room \((store.property(id: id)?.rooms.count ?? 0) + 1)")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNewProperty = true
                    } label: {
                        Label("Start a Walkthrough", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingSignIn) {
                SignInView()
            }
            .sheet(isPresented: $showingNewProperty, onDismiss: {
                capture = nextCapture
                nextCapture = nil
            }) {
                NewPropertyView(defaultName: "Property \(store.properties.count + 1)") { request in
                    nextCapture = request
                    showingNewProperty = false
                }
            }
            .fullScreenCover(item: $capture) { request in
                captureScreen(for: request)
            }
            .onAppear {
                if !welcomeShown {
                    showingWelcome = true
                } else if !RoomCaptureSession.isSupported, !lidarNoticeShown {
                    showingLiDARNotice = true
                }
            }
            .fullScreenCover(isPresented: $showingWelcome, onDismiss: {
                welcomeShown = true
                if !RoomCaptureSession.isSupported, !lidarNoticeShown {
                    showingLiDARNotice = true
                }
            }) {
                WelcomeView()
            }
            .alert("This iPhone doesn't have LiDAR", isPresented: $showingLiDARNotice) {
                Button("OK") { lidarNoticeShown = true }
            } message: {
                Text(LiDARSupport.explanation)
            }
        }
    }

    @ViewBuilder
    private func captureScreen(for request: CaptureRequest) -> some View {
        switch request.mode {
        case .cornerTap:
            CornerMeasureScreen(firstRoomName: request.firstRoomName, onCancel: { capture = nil }) { rooms in
                finish(request, rooms: rooms)
            }
        case .lidar:
            LiDARScanScreen(firstRoomName: request.firstRoomName, modelsDirectory: store.modelsDirectory, onCancel: { capture = nil }) { rooms in
                finish(request, rooms: rooms)
            }
            .ignoresSafeArea()
        }
    }

    private func finish(_ request: CaptureRequest, rooms: [Room]) {
        capture = nil
        let rooms = Layout.tidy(rooms)
        switch request.target {
        case .newProperty(let name, let address, let customer):
            var property = Property(name: name, address: address)
            property.customerName = customer.isEmpty ? nil : customer
            property.rooms = rooms
            store.add(property)
            path = [property.id]
        case .existing(let id):
            guard var property = store.property(id: id) else { return }
            property.append(roomsFromNewSession: rooms)
            store.update(property)
        }
    }
}

private struct PropertyRow: View {
    let property: Property
    let useFeet: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "house")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(property.name).font(.headline)
                if !property.address.isEmpty {
                    Text(property.address).font(.subheadline).foregroundStyle(.secondary)
                }
                Text("\(property.rooms.count) rooms · \(Units.area(property.totalArea, feet: useFeet)) · \(property.itemCount) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct NewPropertyView: View {
    let defaultName: String
    let onStart: (CaptureRequest) -> Void

    @State private var name = ""
    @State private var address = ""
    @State private var customer = ""
    @State private var firstRoom = "Living Room"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Property") {
                    TextField(defaultName, text: $name)
                    TextField("Address (optional)", text: $address)
                    TextField("Customer name (optional)", text: $customer)
                }
                Section {
                    TextField("Living Room", text: $firstRoom)
                } header: {
                    Text("Room you are starting in")
                } footer: {
                    Text("You will map this room first, then tap Next Room as you walk to each of the others. They line up into one floor plan of the whole house.")
                }
                AIFocusSection()
                CaptureModeSection { mode in
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    let trimmedRoom = firstRoom.trimmingCharacters(in: .whitespaces)
                    onStart(CaptureRequest(
                        mode: mode,
                        target: .newProperty(name: trimmedName.isEmpty ? defaultName : trimmedName,
                                             address: address.trimmingCharacters(in: .whitespaces),
                                             customer: customer.trimmingCharacters(in: .whitespaces)),
                        firstRoomName: trimmedRoom.isEmpty ? "Room 1" : trimmedRoom
                    ))
                }
            }
            .navigationTitle("New Walkthrough")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

enum LiDARSupport {
    static var isAvailable: Bool { RoomCaptureSession.isSupported }

    static let explanation = "You can still map rooms by tapping each floor corner, and AI Find Items still recognizes what is in each room. Automatic 3D room scanning needs a LiDAR sensor, found on iPhone 12 Pro and newer Pro models and on iPad Pro."
}

/// The two ways to map rooms, with LiDAR offered only on phones that have it.
struct CaptureModeSection: View {
    let onChoose: (CaptureMode) -> Void
    private let lidarAvailable = RoomCaptureSession.isSupported

    var body: some View {
        Section {
            if lidarAvailable {
                Button {
                    onChoose(.lidar)
                } label: {
                    Label("Scan with LiDAR", systemImage: "cube.transparent")
                }
            } else {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LiDAR scanning not available")
                        Text("This iPhone has no LiDAR sensor.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Button {
                onChoose(.cornerTap)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lidarAvailable ? "Map by tapping corners" : "Start mapping").font(.headline)
                        Text("Tap each corner of the room with the camera")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "ruler")
                }
            }
        } header: {
            Text("Start mapping")
        } footer: {
            Text(lidarAvailable
                 ? "LiDAR scanning measures walls, doors, windows and furniture automatically."
                 : LiDARSupport.explanation)
        }
    }
}
