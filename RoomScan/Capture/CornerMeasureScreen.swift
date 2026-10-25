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
    /// Set when the user is leaving a room the AI has not looked at yet.
    @State private var aiReminder: LeaveAction?
    @State private var showingHelp = false

    private enum LeaveAction: Identifiable {
        case nextRoom
        case done

        var id: Self { self }
    }

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
        .confirmationDialog("Find items in \(roomName) with AI?",
                            isPresented: Binding(get: { aiReminder != nil }, set: { if !$0 { aiReminder = nil } }),
                            titleVisibility: .visible,
                            presenting: aiReminder) { action in
            Button("Scan Now") {
                Task { await controller.scanItemsWithAI(roomName: roomName) }
            }
            Button(action == .done ? "Finish Without Scanning" : "Skip to Next Room") {
                // Let the dialog close before the next-room prompt opens.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { leave(action) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("AI Find Items hasn't looked at this room yet. Point at each wall, and up at the ceiling for lights and vents, then tap AI Find Items for each view.")
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
                Button("Done") { tryLeave(.done) }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.allRooms(currentName: roomName).isEmpty)
            }
            guideCard
            if let message = controller.aiMessage {
                aiBanner(message)
            }
        }
        .sheet(isPresented: $showingHelp) {
            ScanHelpView()
        }
    }

    // MARK: Guide

    private struct Step {
        let number: Int
        let title: String
        let detail: String
    }

    /// Where the user is in mapping this room, and what to do next.
    private var step: Step {
        let corners = controller.corners.count
        let warning = controller.trackingIsNormal ? nil : controller.status
        if controller.aimPoint == nil {
            return Step(number: 1, title: "Find the floor",
                        detail: warning ?? "Point the phone down at the floor and move it slowly side to side until a ring appears under the +.")
        }
        if corners < 3 {
            let detail = corners == 0
                ? "Aim the + at a corner where two walls meet the floor, then tap Add Corner."
                : "Corner \(corners) added. Follow the wall to the next corner, aim the + at it and tap Add Corner."
            return Step(number: 2, title: "Mark the corners", detail: warning ?? detail)
        }
        if controller.aiScansThisRoom == 0 {
            let detail = APIKeyStore.hasKey
                ? "Add any remaining corners. Then point at one wall and tap AI Find Items."
                : "Add any remaining corners. Then aim the + at each item on the floor and tap the pin button. (Add a Claude key in Settings to let AI find items.)"
            return Step(number: 3, title: "Find the items", detail: warning ?? detail)
        }
        return Step(number: 4, title: "Finish this room",
                    detail: warning ?? "Scan the other walls and tilt up for the ceiling with AI Find Items. Then tap Next Room, or Done if this was the last room.")
    }

    private var guideCard: some View {
        let step = step
        return HStack(alignment: .top, spacing: 12) {
            Text("\(step.number)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text("Step \(step.number) of 4 · \(step.title)")
                    .font(.subheadline.bold())
                Text(step.detail)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                showingHelp = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.title3)
            }
            .accessibilityLabel("How to scan")
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .animation(.default, value: step.number)
    }

    /// What the last AI scan did, with the items it added and a way to take them back.
    private func aiBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Label(message, systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Button {
                    controller.dismissAIMessage()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
            if !controller.lastAIAdded.isEmpty {
                Text(controller.lastAIAdded.map(\.name).joined(separator: ", "))
                    .font(.caption)
                    .lineLimit(3)
                HStack {
                    Text("Wrong items? Undo, or change what AI looks for below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Undo") { controller.undoLastAIScan() }
                        .font(.caption.bold())
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
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
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("AI is looking…")
                            }
                        } else {
                            Label("AI Find Items", systemImage: "sparkles")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 36)
                }
                .modifier(Emphasized(on: step.number == 3))
                .disabled(controller.isAnalyzing)

                Button {
                    tryLeave(.nextRoom)
                } label: {
                    Label("Next Room", systemImage: "arrow.right.square")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .modifier(Emphasized(on: step.number == 4))
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
                .modifier(Emphasized(on: step.number <= 2))
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

    /// Reminds the user to run AI Find Items before leaving a room it has not seen.
    private func tryLeave(_ action: LeaveAction) {
        let roomInProgress = controller.corners.count >= 3
        if roomInProgress, controller.aiScansThisRoom == 0, APIKeyStore.hasKey {
            aiReminder = action
        } else {
            leave(action)
        }
    }

    private func leave(_ action: LeaveAction) {
        switch action {
        case .nextRoom: askingRoomName = true
        case .done: onFinish(controller.allRooms(currentName: roomName))
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

/// Fills the button for the step the user is on, so the next thing to tap stands out.
private struct Emphasized: ViewModifier {
    let on: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if on {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
