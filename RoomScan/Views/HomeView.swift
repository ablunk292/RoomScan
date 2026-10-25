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
    @AppStorage(Units.useFeetKey) private var useFeet = true
    @State private var path: [Property.ID] = []
    @State private var showingNewProperty = false
    @State private var showingSettings = false
    @State private var capture: CaptureRequest?
    /// Chosen in the New Property sheet; opened once the sheet has finished closing,
    /// since SwiftUI cannot present a full-screen view while a sheet is dismissing.
    @State private var nextCapture: CaptureRequest?
    @AppStorage("lidarNoticeShown") private var lidarNoticeShown = false
    @State private var showingLiDARNotice = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if store.properties.isEmpty {
                    ContentUnavailableView(
                        "No properties yet",
                        systemImage: "house",
                        description: Text("Tap + to map a house, apartment or building.")
                    )
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
                        Label("New Property", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
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
                if !RoomCaptureSession.isSupported, !lidarNoticeShown {
                    showingLiDARNotice = true
                }
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

    var body: some View {
        NavigationStack {
            Form {
                Section("Property") {
                    TextField(defaultName, text: $name)
                    TextField("Address (optional)", text: $address)
                    TextField("Customer name (optional)", text: $customer)
                }
                Section {
                    TextField("First room", text: $firstRoom)
                } footer: {
                    Text("Map each room in turn and tap Next Room as you walk through. Rooms mapped in one go line up into a whole-house floor plan.")
                }
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
            .navigationTitle("New Property")
            .navigationBarTitleDisplayMode(.inline)
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
                Label("Map by tapping corners", systemImage: "ruler")
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
