import ARKit
import SwiftUI

/// Maps one or more rooms by tapping floor corners. Walk from room to room and tap Next Room;
/// all rooms from one session line up into a single floor plan.
struct CornerMeasureScreen: View {
    let firstRoomName: String
    let onCancel: () -> Void
    let onFinish: ([Room]) -> Void

    @StateObject private var controller = CornerMeasureController()
    @AppStorage(Units.useFeetKey) private var useFeet = true
    @State private var roomName: String
    @State private var askingItemName = false
    @State private var itemName = ""
    @State private var askingRoomName = false
    @State private var nextRoomName = ""
    @State private var confirmingCancel = false

    init(firstRoomName: String, onCancel: @escaping () -> Void, onFinish: @escaping ([Room]) -> Void) {
        self.firstRoomName = firstRoomName
        self.onCancel = onCancel
        self.onFinish = onFinish
        _roomName = State(initialValue: firstRoomName)
    }

    var body: some View {
        ZStack {
            ARViewContainer(view: controller.sceneView)
                .ignoresSafeArea()

            Image(systemName: "plus")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white)
                .shadow(radius: 2)
                .allowsHitTesting(false)

            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding()
        }
        .onAppear { controller.start() }
        .onDisappear { controller.pause() }
        .alert("Add item here", isPresented: $askingItemName) {
            TextField("Outlet, thermostat, TV…", text: $itemName)
            Button("Add") {
                let name = itemName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { controller.addItem(named: name) }
                itemName = ""
            }
            Button("Cancel", role: .cancel) { itemName = "" }
        } message: {
            Text("The item is pinned where the crosshair points. You can add details after saving.")
        }
        .alert("Next room", isPresented: $askingRoomName) {
            TextField("Kitchen, Bedroom 2…", text: $nextRoomName)
            Button("Start") {
                if controller.finishCurrentRoom(named: roomName) {
                    let name = nextRoomName.trimmingCharacters(in: .whitespaces)
                    roomName = name.isEmpty ? "Room \(controller.finishedRooms.count + 1)" : name
                }
                nextRoomName = ""
            }
            Button("Cancel", role: .cancel) { nextRoomName = "" }
        } message: {
            Text("\(roomName) is saved. Walk into the next room and map its corners.")
        }
        .confirmationDialog("Discard this scan?", isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                (controller.finishedRooms.flatMap(\.items) + controller.items).forEach { ItemPhotos.delete($0.photoFileName) }
                onCancel()
            }
        } message: {
            Text("The rooms mapped in this session will not be saved.")
        }
    }

    private var hasWork: Bool {
        !controller.corners.isEmpty || !controller.finishedRooms.isEmpty || !controller.items.isEmpty
    }

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Cancel") {
                    if hasWork { confirmingCancel = true } else { onCancel() }
                }
                .buttonStyle(.bordered)
                Spacer()
                VStack(spacing: 0) {
                    Text(roomName).font(.headline)
                    if !controller.finishedRooms.isEmpty {
                        Text("\(controller.finishedRooms.count) room\(controller.finishedRooms.count == 1 ? "" : "s") done")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                Spacer()
                Button("Done") { onFinish(controller.allRooms(currentName: roomName)) }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.allRooms(currentName: roomName).isEmpty)
            }
            Text(controller.aiMessage ?? (controller.aimPoint == nil
                ? "Point the phone down at the floor and move slowly until the crosshair ring appears."
                : controller.status))
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .onTapGesture { controller.aiMessage = nil }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            AIFocusButton()

            HStack(spacing: 16) {
                stat("Corners", "\(controller.corners.count)")
                if let distance = controller.liveDistance {
                    stat("This wall", Units.length(distance, feet: useFeet))
                }
                if controller.corners.count >= 3 {
                    stat("Area", Units.area(controller.currentArea, feet: useFeet))
                }
                stat("Items", "\(controller.items.count)")
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 12) {
                Button {
                    Task { await controller.scanItemsWithAI(roomName: roomName) }
                } label: {
                    Group {
                        if controller.isAnalyzing {
                            ProgressView()
                        } else {
                            Label("AI Find Items", systemImage: "sparkles")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .disabled(controller.isAnalyzing)

                Button {
                    askingRoomName = true
                } label: {
                    Label("Next Room", systemImage: "arrow.right.square")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .disabled(controller.corners.count < 3)
            }

            HStack(spacing: 12) {
                Button {
                    controller.undoCorner()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .disabled(controller.corners.isEmpty)

                Button {
                    controller.addCorner()
                } label: {
                    Label("Add Corner", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.aimPoint == nil)

                Button {
                    askingItemName = true
                } label: {
                    Image(systemName: "mappin.and.ellipse")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .disabled(controller.aimPoint == nil)
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.semibold))
        }
    }
}

struct ARViewContainer: UIViewRepresentable {
    let view: ARSCNView

    func makeUIView(context: Context) -> ARSCNView { view }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
