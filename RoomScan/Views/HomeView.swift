import RoomPlan
import SwiftUI

enum CaptureMode: String, Identifiable {
    case cornerTap
    case lidar

    var id: String { rawValue }
}

struct HomeView: View {
    @EnvironmentObject private var store: RoomStore
    @AppStorage(Units.useFeetKey) private var useFeet = true
    @State private var path: [Room.ID] = []
    @State private var showingNewRoom = false
    @State private var pendingName = ""
    @State private var captureMode: CaptureMode?
    /// Chosen in the New Room sheet; opened once the sheet has finished closing,
    /// since SwiftUI cannot present a full-screen view while a sheet is dismissing.
    @State private var nextMode: CaptureMode?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if store.rooms.isEmpty {
                    ContentUnavailableView(
                        "No rooms yet",
                        systemImage: "viewfinder",
                        description: Text("Tap New Room to measure your first room.")
                    )
                    .listRowBackground(Color.clear)
                }
                ForEach(store.rooms) { room in
                    NavigationLink(value: room.id) {
                        RoomRow(room: room, useFeet: useFeet)
                    }
                }
                .onDelete { store.delete(at: $0) }
            }
            .navigationTitle("RoomScan")
            .navigationDestination(for: Room.ID.self) { id in
                RoomDetailView(roomID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Picker("Units", selection: $useFeet) {
                        Text("ft").tag(true)
                        Text("m").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 90)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        pendingName = "Room \(store.rooms.count + 1)"
                        showingNewRoom = true
                    } label: {
                        Label("New Room", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNewRoom, onDismiss: {
                captureMode = nextMode
                nextMode = nil
            }) {
                NewRoomView(name: $pendingName) { mode in
                    nextMode = mode
                    showingNewRoom = false
                }
                .presentationDetents([.medium])
            }
            .fullScreenCover(item: $captureMode) { mode in
                captureScreen(for: mode)
            }
        }
    }

    @ViewBuilder
    private func captureScreen(for mode: CaptureMode) -> some View {
        let name = pendingName.trimmingCharacters(in: .whitespaces).isEmpty ? "Room" : pendingName
        switch mode {
        case .cornerTap:
            CornerMeasureScreen(roomName: name, onCancel: { captureMode = nil }, onFinish: finish)
        case .lidar:
            LiDARScanScreen(roomName: name, modelsDirectory: store.modelsDirectory, onCancel: { captureMode = nil }, onFinish: finish)
        }
    }

    private func finish(_ room: Room) {
        store.add(room)
        captureMode = nil
        path = [room.id]
    }
}

private struct RoomRow: View {
    let room: Room
    let useFeet: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: room.method == .lidar ? "cube.transparent" : "ruler")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(room.name).font(.headline)
                Text("\(Units.area(room.area, feet: useFeet)) · \(room.items.count) items")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct NewRoomView: View {
    @Binding var name: String
    let onStart: (CaptureMode) -> Void

    private let lidarAvailable = RoomCaptureSession.isSupported

    var body: some View {
        NavigationStack {
            Form {
                Section("Room name") {
                    TextField("Kitchen, Office 101…", text: $name)
                }
                Section {
                    Button {
                        onStart(.lidar)
                    } label: {
                        Label("Scan with LiDAR", systemImage: "cube.transparent")
                    }
                    .disabled(!lidarAvailable)

                    Button {
                        onStart(.cornerTap)
                    } label: {
                        Label("Measure by tapping corners", systemImage: "ruler")
                    }
                } footer: {
                    Text(lidarAvailable
                         ? "LiDAR scanning measures walls, doors, windows and furniture automatically."
                         : "This phone has no LiDAR sensor, so it measures by tapping each corner of the floor. LiDAR scanning needs an iPhone Pro (12 Pro or newer) or iPad Pro.")
                }
            }
            .navigationTitle("New Room")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
