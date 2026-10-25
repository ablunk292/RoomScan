import ARKit
import SceneKit
import UIKit

/// Runs the AR session for mapping rooms by tapping their floor corners.
/// Works on any iPhone with ARKit; it does not need LiDAR.
///
/// The crosshair in the middle of the screen is projected onto the floor every frame.
/// Corners and item pins are dropped where the crosshair meets the floor. Several rooms can
/// be mapped in one session; they share the same coordinates, so a whole house lines up.
final class CornerMeasureController: NSObject, ObservableObject, ARSCNViewDelegate, ARSessionDelegate {
    @Published private(set) var corners: [SIMD3<Float>] = []
    @Published private(set) var items: [RoomItem] = []
    @Published private(set) var finishedRooms: [Room] = []
    @Published private(set) var aimPoint: SIMD3<Float>?
    @Published private(set) var status = "Move your phone slowly to find the floor."
    @Published private(set) var isAnalyzing = false
    /// Result of the last AI scan, shown briefly on screen.
    @Published var aiMessage: String?

    let sceneView = ARSCNView()

    private let reticle = CornerMeasureController.makeReticle()
    private var cornerNodes: [SCNNode] = []
    private var segmentNodes: [SCNNode] = []
    private let liveSegment = CornerMeasureController.makeSegment(from: .zero, to: SIMD3<Float>(0, 0, 0.01), color: .white)
    /// Height of the floor in AR coordinates, once a floor plane has been found.
    private var floorY: Float?
    /// Where the crosshair meets the floor, smoothed every frame.
    private var smoothedAim: SIMD3<Float>?
    private var lastPublish: CFTimeInterval = 0
    private var closingSegment: SCNNode?
    private var updatePending = false

    /// Distance from the last corner to the crosshair, in meters.
    var liveDistance: Double? {
        guard let last = corners.last, let aim = aimPoint else { return nil }
        return Double(simd_distance(last, aim))
    }

    var currentArea: Double {
        Geometry.area(of: corners.map(Self.floorPoint))
    }

    override init() {
        super.init()
        sceneView.delegate = self
        sceneView.session.delegate = self
        sceneView.automaticallyUpdatesLighting = true
        reticle.isHidden = true
        sceneView.scene.rootNode.addChildNode(reticle)
        liveSegment.isHidden = true
        sceneView.scene.rootNode.addChildNode(liveSegment)

        let coaching = ARCoachingOverlayView()
        coaching.session = sceneView.session
        coaching.goal = .horizontalPlane
        coaching.activatesAutomatically = true
        coaching.translatesAutoresizingMaskIntoConstraints = false
        sceneView.addSubview(coaching)
        NSLayoutConstraint.activate([
            coaching.leadingAnchor.constraint(equalTo: sceneView.leadingAnchor),
            coaching.trailingAnchor.constraint(equalTo: sceneView.trailingAnchor),
            coaching.topAnchor.constraint(equalTo: sceneView.topAnchor),
            coaching.bottomAnchor.constraint(equalTo: sceneView.bottomAnchor),
        ])
    }

    func start() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func pause() {
        sceneView.session.pause()
    }

    // MARK: Corners

    func addCorner() {
        guard let point = smoothedAim else { return }
        // Keep every corner at the height of the first one, so small floor
        // detection errors do not tilt the room.
        var corner = point
        if let first = corners.first { corner.y = first.y }

        if let last = corners.last {
            let segment = Self.makeSegment(from: last, to: corner)
            sceneView.scene.rootNode.addChildNode(segment)
            segmentNodes.append(segment)
        }
        let node = Self.makeCornerMarker()
        node.simdPosition = corner
        sceneView.scene.rootNode.addChildNode(node)
        cornerNodes.append(node)
        corners.append(corner)
        updateClosingSegment()
    }

    func undoCorner() {
        guard !corners.isEmpty else { return }
        corners.removeLast()
        cornerNodes.popLast()?.removeFromParentNode()
        if !segmentNodes.isEmpty, segmentNodes.count >= corners.count {
            segmentNodes.popLast()?.removeFromParentNode()
        }
        updateClosingSegment()
    }

    // MARK: Items

    func addItem(named name: String) {
        guard let point = smoothedAim else { return }
        addItem(RoomItem(name: name), at: point)
    }

    /// Takes a photo of what the camera sees and asks the AI to find and pin the items in it.
    @MainActor
    func scanItemsWithAI(roomName: String) async {
        guard !isAnalyzing else { return }
        guard let frame = sceneView.session.currentFrame, let photo = FramePhoto(frame: frame) else {
            aiMessage = "Camera not ready yet."
            return
        }
        isAnalyzing = true
        defer { isAnalyzing = false }
        do {
            let detected = try await ItemDetector.detectItems(inJPEG: photo.jpeg, roomName: roomName,
                                                                focus: DetectionPresets.shared.activeFocus)
            var added = 0
            for found in detected {
                let position = photo.worldPosition(x: found.x, y: found.y, in: sceneView.session)
                if isDuplicate(name: found.name, at: position) { continue }
                let item = RoomItem(
                    name: found.name,
                    category: found.category,
                    condition: found.condition,
                    notes: found.notes,
                    detectedAutomatically: true,
                    photoFileName: photo.closeUp(of: found).flatMap { ItemPhotos.save($0) }
                )
                addItem(item, at: position)
                added += 1
            }
            aiMessage = Self.summary(found: detected.count, added: added)
        } catch {
            aiMessage = error.localizedDescription
        }
        let shown = aiMessage
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if self?.aiMessage == shown { self?.aiMessage = nil }
        }
    }

    /// What one AI scan did, for the status line.
    static func summary(found: Int, added: Int) -> String {
        if found == 0 { return "No items recognized. Step back so more of the room is in view." }
        if added == 0 { return "Found \(found) items, all already on the list. Try another wall." }
        if added == found { return "Added \(added) item\(added == 1 ? "" : "s")." }
        return "Found \(found) items, added \(added) new."
    }

    private func addItem(_ item: RoomItem, at position: SIMD3<Float>?) {
        var item = item
        if let position {
            item.position = Self.floorPoint(position)
            let node = Self.makeItemMarker(detected: item.detectedAutomatically)
            node.simdPosition = position
            sceneView.scene.rootNode.addChildNode(node)
        }
        items.append(item)
    }

    /// The same thing seen again from another angle: same name, within half a meter.
    private func isDuplicate(name: String, at position: SIMD3<Float>?) -> Bool {
        guard let position else { return false }
        let point = Self.floorPoint(position)
        return items.contains { item in
            guard let other = item.position else { return false }
            return item.name.caseInsensitiveCompare(name) == .orderedSame && Geometry.distance(point, other) < 0.25
        }
    }

    // MARK: Rooms

    /// Saves the room being mapped and clears the way for the next one. The finished room's
    /// outline stays visible, dimmed, so the next room can start from a shared wall.
    @discardableResult
    func finishCurrentRoom(named name: String) -> Bool {
        guard corners.count >= 3 else { return false }
        finishedRooms.append(Room(name: name, method: .cornerTap, outline: corners.map(Self.floorPoint), items: items))

        if let first = corners.first, let last = corners.last {
            segmentNodes.append(Self.makeSegment(from: last, to: first))
            sceneView.scene.rootNode.addChildNode(segmentNodes[segmentNodes.count - 1])
        }
        for node in segmentNodes + cornerNodes {
            node.geometry?.firstMaterial?.diffuse.contents = UIColor.systemGray
        }
        closingSegment?.removeFromParentNode()
        closingSegment = nil
        segmentNodes = []
        cornerNodes = []
        corners = []
        items = []
        return true
    }

    /// Every room mapped in this session, including the one in progress if it has enough corners.
    func allRooms(currentName: String) -> [Room] {
        var rooms = finishedRooms
        if corners.count >= 3 {
            rooms.append(Room(name: currentName, method: .cornerTap, outline: corners.map(Self.floorPoint), items: items))
        }
        return rooms
    }

    private static func floorPoint(_ point: SIMD3<Float>) -> Point2D {
        Point2D(x: Double(point.x), y: Double(point.z))
    }

    // MARK: Frame updates

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard !updatePending else { return }
        updatePending = true
        DispatchQueue.main.async { [weak self] in
            self?.updateAim()
            self?.updatePending = false
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        updateFloorHeight(from: anchors, cameraY: session.currentFrame?.camera.transform.columns.3.y)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        updateFloorHeight(from: anchors, cameraY: session.currentFrame?.camera.transform.columns.3.y)
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let message: String
        switch camera.trackingState {
        case .normal:
            message = "Aim the crosshair at a floor corner and tap Add Corner."
        case .limited(.excessiveMotion):
            message = "Slow down."
        case .limited(.insufficientFeatures):
            message = "Too dark or too plain. Point at the floor where there is more detail."
        case .limited(.initializing), .limited(.relocalizing):
            message = "Getting ready… move your phone slowly."
        case .notAvailable:
            message = "Tracking unavailable."
        default:
            message = "Move your phone slowly."
        }
        DispatchQueue.main.async { self.status = message }
    }

    /// The floor is the lowest large flat surface well below the phone. Once known, the
    /// crosshair is projected straight onto it, which is far steadier than per-frame
    /// raycasts that jump between rough surface guesses.
    private func updateFloorHeight(from anchors: [ARAnchor], cameraY: Float?) {
        guard let cameraY else { return }
        for case let plane as ARPlaneAnchor in anchors where plane.alignment == .horizontal {
            let y = plane.transform.columns.3.y
            let size = plane.planeExtent.width * plane.planeExtent.height
            let looksLikeFloor = plane.classification == .floor || size > 0.5
            guard looksLikeFloor, cameraY - y > 0.6 else { continue }
            DispatchQueue.main.async {
                if self.floorY == nil || y < self.floorY! { self.floorY = y }
            }
        }
    }

    private func updateAim() {
        guard let frame = sceneView.session.currentFrame else { return }
        // Until the floor is found the coaching overlay asks the user to look around.
        let height = corners.first?.y ?? floorY
        var target: SIMD3<Float>?

        if let height {
            // The middle of the screen looks straight down the camera's -z axis.
            let camera = frame.camera.transform
            let origin = SIMD3<Float>(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
            let forward = -SIMD3<Float>(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z)
            if forward.y < -0.08 {
                let distance = (height - origin.y) / forward.y
                if distance > 0, distance < 12 { target = origin + forward * distance }
            }
        }

        // Smooth out hand shake; jump straight to big moves.
        if let target {
            if let previous = smoothedAim, simd_distance(previous, target) < 0.4 {
                smoothedAim = simd_mix(previous, target, SIMD3<Float>(repeating: 0.3))
            } else {
                smoothedAim = target
            }
        } else {
            smoothedAim = nil
        }

        guard let point = smoothedAim else {
            reticle.isHidden = true
            liveSegment.isHidden = true
            if aimPoint != nil { aimPoint = nil }
            return
        }
        reticle.simdPosition = point
        reticle.isHidden = false
        if let last = corners.last, simd_distance(last, point) > 0.01 {
            Self.place(liveSegment, from: last, to: point)
            liveSegment.isHidden = false
        } else {
            liveSegment.isHidden = true
        }

        // Screen readouts only need about 10 updates a second; redrawing SwiftUI every frame stutters.
        let now = CACurrentMediaTime()
        if aimPoint == nil || now - lastPublish > 0.1 {
            aimPoint = point
            lastPublish = now
        }
    }

    /// Faint line from the last corner back to the first, so the user sees the room close.
    private func updateClosingSegment() {
        closingSegment?.removeFromParentNode()
        closingSegment = nil
        guard corners.count >= 3, let first = corners.first, let last = corners.last else { return }
        let segment = Self.makeSegment(from: last, to: first, color: UIColor.systemYellow.withAlphaComponent(0.4))
        sceneView.scene.rootNode.addChildNode(segment)
        closingSegment = segment
    }

    // MARK: Scene nodes

    private static func makeReticle() -> SCNNode {
        let ring = SCNTorus(ringRadius: 0.05, pipeRadius: 0.004)
        ring.firstMaterial?.diffuse.contents = UIColor.white
        ring.firstMaterial?.lightingModel = .constant
        let dot = SCNSphere(radius: 0.008)
        dot.firstMaterial?.diffuse.contents = UIColor.white
        dot.firstMaterial?.lightingModel = .constant
        let node = SCNNode(geometry: ring)
        node.addChildNode(SCNNode(geometry: dot))
        return node
    }

    private static func makeCornerMarker() -> SCNNode {
        let sphere = SCNSphere(radius: 0.02)
        sphere.firstMaterial?.diffuse.contents = UIColor.systemYellow
        sphere.firstMaterial?.lightingModel = .constant
        return SCNNode(geometry: sphere)
    }

    /// A small ball where the item is (on a wall, the floor or furniture).
    private static func makeItemMarker(detected: Bool) -> SCNNode {
        let ball = SCNSphere(radius: 0.03)
        ball.firstMaterial?.diffuse.contents = detected ? UIColor.systemPurple : UIColor.systemTeal
        ball.firstMaterial?.lightingModel = .constant
        return SCNNode(geometry: ball)
    }

    private static func makeSegment(from a: SIMD3<Float>, to b: SIMD3<Float>, color: UIColor = .systemYellow) -> SCNNode {
        let cylinder = SCNCylinder(radius: 0.005, height: 0.01)
        cylinder.firstMaterial?.diffuse.contents = color
        cylinder.firstMaterial?.lightingModel = .constant
        let node = SCNNode(geometry: cylinder)
        place(node, from: a, to: b)
        return node
    }

    /// Stretches a line node between two points.
    private static func place(_ node: SCNNode, from a: SIMD3<Float>, to b: SIMD3<Float>) {
        let length = simd_distance(a, b)
        (node.geometry as? SCNCylinder)?.height = CGFloat(length)
        node.simdPosition = (a + b) / 2
        if length > 0.0001 {
            node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(b - a))
        }
    }
}
