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
    /// The user chose to finish this room without the AI (no API key), pinning items by hand.
    @State private var mappedWithoutAI = false
    @State private var askingForKey = false
    @State private var measuring = false
    /// Set when the user tries to leave a room whose outline is not closed yet.
    @State private var closeReminder: LeaveAction?
    @State private var addingRequest = false

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
            Color.black.ignoresSafeArea()
            // The camera image is 3:4. Showing all of it, instead of filling the screen and
            // cutting off the sides, shows exactly what the AI sees.
            ARViewContainer(view: controller.sceneView)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)

            Image(systemName: "plus")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white)
                .shadow(radius: 2)
                .allowsHitTesting(false)

            if let angle = controller.turnAngle, !measuring {
                // Points toward the part to scan when it is off screen.
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 56))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .orange)
                    .shadow(radius: 4)
                    .rotationEffect(.radians(-angle))
                    .offset(x: cos(angle) * 120, y: -sin(angle) * 120)
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.2), value: angle)
            }

            if controller.movingTooFast {
                Label("Slow down", systemImage: "tortoise.fill")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.red.opacity(0.85), in: Capsule())
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

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
                    mappedWithoutAI = false
                    measuring = false
                    let name = nextRoomName.trimmingCharacters(in: .whitespaces)
                    roomName = name.isEmpty ? "Room \(controller.finishedRooms.count + 1)" : name
                }
                nextRoomName = ""
            }
            Button("Cancel", role: .cancel) { nextRoomName = "" }
        } message: {
            Text("\(roomName) is saved. Walk into the next room and map its corners.")
        }
        .alert("Close the room first", isPresented: Binding(get: { closeReminder != nil }, set: { if !$0 { closeReminder = nil } }),
               presenting: closeReminder) { action in
            if controller.corners.count >= 3 {
                Button("Close It Now") {
                    controller.closeRoom()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { tryLeave(action) }
                }
            }
            if controller.corners.count < 3, action == .done, !controller.finishedRooms.isEmpty {
                Button("Finish Without This Room") { leave(.done) }
            }
            Button("Keep Mapping", role: .cancel) {}
        } message: { _ in
            Text(controller.corners.count >= 3
                 ? "Walk back to the first corner (pulsing green) and tap Close Room, or close it now with a straight wall from the last corner."
                 : "\(roomName) needs at least 3 corners. Keep marking corners, then come back to the first one.")
        }
        .alert("Sign in to scan items with AI", isPresented: $askingForKey) {
            Button("Pin Items by Hand") { mappedWithoutAI = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The AI item scan needs you to sign in with your QuoteMaster account in Settings on the home screen. For now you can aim the + at items and tap the pin button.")
        }
        .confirmationDialog("Scan the items in \(roomName) first?",
                            isPresented: Binding(get: { aiReminder != nil }, set: { if !$0 { aiReminder = nil } }),
                            titleVisibility: .visible,
                            presenting: aiReminder) { action in
            Button("Scan Items") {
                if !controller.itemScanActive { controller.startItemScan(roomName: roomName) }
            }
            Button(action == .done ? "Finish Without Scanning" : "Skip to Next Room") {
                // Let the dialog close before the next-room prompt opens.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { leave(action) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(controller.itemScanActive
                 ? "Some walls, the ceiling or the floor haven't been scanned yet. Follow the orange highlight to finish."
                 : "The AI hasn't looked at this room yet. It takes about a minute: you point at each wall in turn and it does the rest.")
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
                Button {
                    setMeasuring(!measuring)
                } label: {
                    Image(systemName: "ruler")
                }
                .buttonStyle(.bordered)
                .tint(measuring ? Color.accentColor : nil)
                .accessibilityLabel("Measure")
                Button {
                    addingRequest = true
                } label: {
                    let count = controller.items.filter(\.isRequested).count
                    Image(systemName: "cart.badge.plus")
                        .overlay(alignment: .topTrailing) {
                            if count > 0 {
                                Text("\(count)")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                                    .padding(3)
                                    .background(Circle().fill(.pink))
                                    .offset(x: 10, y: -10)
                            }
                        }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Add client request")
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
                    .disabled(controller.allRooms(currentName: roomName).isEmpty || controller.pendingRequests > 0)
            }
            guideCard
            if let message = controller.aiMessage {
                aiBanner(message)
            }
        }
        .sheet(isPresented: $showingHelp) {
            ScanHelpView()
        }
        .sheet(isPresented: $addingRequest) {
            ClientRequestSheet(controller: controller, roomName: roomName)
        }
        .task(id: controller.aiMessage) {
            // Each AI result shows for a few seconds, unless a newer one replaces it.
            guard let shown = controller.aiMessage else { return }
            try? await Task.sleep(for: .seconds(8))
            if controller.aiMessage == shown { controller.dismissAIMessage() }
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
        if measuring {
            return Step(number: 0, title: "Measure",
                        detail: "Tap Set Point at each end of what you want to measure, then name it to save it to this room.")
        }
        if controller.measuringCeiling {
            return Step(number: 3, title: "Ceiling height", detail: warning ?? controller.scanGuidance)
        }
        if controller.itemScanActive {
            if controller.itemScanComplete || controller.currentTarget == nil {
                return Step(number: 4, title: "Room done", detail: controller.scanGuidance)
            }
            return Step(number: 3, title: "Scan the items", detail: warning ?? controller.scanGuidance)
        }
        if mappedWithoutAI {
            return Step(number: 4, title: "Room done",
                        detail: "Aim the + at items on the floor and tap the pin button to add them. Then tap Next Room, or Done if this was the last room.")
        }
        if controller.aimPoint == nil, corners < 3 {
            return Step(number: 1, title: "Find the floor",
                        detail: warning ?? "Point the phone down at the floor and move it slowly side to side until a ring appears under the +.")
        }
        let detail: String
        switch corners {
        case 0: detail = "Aim the + at a corner where two walls meet the floor, then tap Add Corner."
        case 1, 2: detail = "Corner \(corners) added. Follow the wall to the next corner, aim the + at it and tap Add Corner."
        default:
            if controller.roomClosed {
                detail = "Room closed. Tap Room Mapped to scan the items."
            } else if controller.aimAtFirstCorner {
                detail = "You're back at the first corner. Tap Close Room to finish the outline."
            } else {
                detail = "Corner \(corners) added. Keep going around the room. To finish, aim the + back at the first corner (the pulsing green one) and tap Close Room."
            }
        }
        return Step(number: 2, title: "Mark the corners", detail: warning ?? detail)
    }

    private var guideCard: some View {
        let step = step
        return HStack(alignment: .top, spacing: 12) {
            Group {
                if step.number == 0 {
                    Image(systemName: "ruler")
                } else {
                    Text("\(step.number)")
                }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(step.number == 0 ? step.title : "Step \(step.number) of 4 · \(step.title)")
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
        .animation(.default, value: controller.movingTooFast)
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

    @ViewBuilder
    private var bottomBar: some View {
        if measuring {
            MeasurePanel(tool: controller.measureTool, useFeet: useFeet, savedCount: controller.measurements.count,
                         onSave: { controller.measurements.append($0) },
                         onClose: { setMeasuring(false) })
        } else if controller.measuringCeiling {
            ceilingBar
        } else if controller.itemScanActive {
            scanBar
        } else {
            mappingBar
        }
    }

    private func setMeasuring(_ on: Bool) {
        measuring = on
        controller.measureTool.isShowing = on
    }

    /// Measuring the ceiling height at the top of a wall.
    private var ceilingBar: some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text("Ceiling height").font(.caption).foregroundStyle(.secondary)
                Text(controller.liveCeilingHeight.map { Units.length(Double($0), feet: useFeet) } ?? "—")
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

            Button {
                controller.confirmCeilingHeight()
            } label: {
                Label("Set Ceiling Height", systemImage: "arrow.up.to.line")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.liveCeilingHeight == nil)

            Button("Skip (assume 8 ft)") {
                controller.skipCeilingHeight()
            }
            .font(.subheadline)
        }
    }

    /// Mapping the corners, with Room Mapped once there are enough.
    private var mappingBar: some View {
        VStack(spacing: 12) {
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

            if controller.roomClosed {
                if mappedWithoutAI {
                    leaveButtons
                } else {
                    AIFocusButton()
                    Button {
                        startItemScan()
                    } label: {
                        Label("Room Mapped – Scan Items", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
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
                    Group {
                        if controller.roomClosed {
                            Label("Room Closed", systemImage: "checkmark")
                        } else if controller.aimAtFirstCorner {
                            Label("Close Room", systemImage: "arrow.triangle.capsulepath")
                        } else {
                            Label("Add Corner", systemImage: "plus.circle.fill")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .modifier(Emphasized(on: !controller.roomClosed))
                .tint(controller.aimAtFirstCorner ? Color.green : nil)
                .disabled(controller.aimPoint == nil || controller.roomClosed)

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

    /// The guided item scan: progress through the walls, ceiling and floor.
    private var scanBar: some View {
        VStack(spacing: 12) {
            AIFocusButton()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(controller.scanTargets, id: \.self) { target in
                        targetChip(target)
                    }
                }
                .padding(.horizontal, 2)
            }

            if controller.currentTarget != nil {
                HStack(spacing: 12) {
                    Button {
                        controller.skipCurrentTarget()
                    } label: {
                        Label("Skip", systemImage: "forward")
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        controller.captureNow()
                    } label: {
                        Label("Snap Now", systemImage: "camera")
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        controller.stopItemScan()
                    } label: {
                        Label("Corners", systemImage: "ruler")
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                }
                .font(.subheadline)
            } else {
                leaveButtons
            }
        }
    }

    private var leaveButtons: some View {
        HStack(spacing: 12) {
            Button {
                tryLeave(.nextRoom)
            } label: {
                Label("Next Room", systemImage: "arrow.right.square")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)

            Button {
                tryLeave(.done)
            } label: {
                Label("Done", systemImage: "checkmark")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
        .disabled(controller.pendingRequests > 0)
    }

    private func targetChip(_ target: CornerMeasureController.ScanTarget) -> some View {
        let isCurrent = controller.currentTarget == target
        let done = controller.targetsDone.contains(target)
        let coverage = controller.coverage(of: target)
        return HStack(spacing: 4) {
            if done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if coverage > 0 {
                ProgressView().controlSize(.mini)
            }
            Text(target.label)
        }
        .font(.caption.weight(isCurrent ? .bold : .regular))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isCurrent ? AnyShapeStyle(Color.orange.opacity(0.85)) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
        .foregroundStyle(isCurrent ? Color.white : Color.primary)
    }

    private func startItemScan() {
        guard AIAccess.isAvailable else {
            askingForKey = true
            return
        }
        controller.startItemScan(roomName: roomName)
    }

    /// Reminds the user to scan the items before leaving a room the AI has not finished.
    private func tryLeave(_ action: LeaveAction) {
        if !controller.corners.isEmpty, !controller.roomClosed {
            closeReminder = action
            return
        }
        let roomInProgress = controller.corners.count >= 3
        let scanned = controller.itemScanActive && controller.currentTarget == nil
        if roomInProgress, !scanned, !mappedWithoutAI, AIAccess.isAvailable {
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
