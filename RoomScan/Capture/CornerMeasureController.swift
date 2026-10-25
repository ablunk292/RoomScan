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
    private var liveSegment: SCNNode?
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
        guard let point = aimPoint else { return }
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
        guard let point = aimPoint else { return }
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
            let detected = try await ItemDetector.detectItems(inJPEG: photo.jpeg, roomName: roomName)
            var added = 0
            for found in detected {
                let position = photo.worldPosition(x: found.x, y: found.y, in: sceneView.session)
                if isDuplicate(name: found.name, at: position) { continue }
                let item = RoomItem(
                    name: found.name,
                    category: found.category,
                    condition: found.condition,
                    notes: found.notes,
                    detectedAutomatically: true
                )
                addItem(item, at: position)
                added += 1
            }
            aiMessage = added == 0 ? "No new items found. Try another angle." : "Added \(added) item\(added == 1 ? "" : "s")."
        } catch {
            aiMessage = error.localizedDescription
        }
        let shown = aiMessage
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if self?.aiMessage == shown { self?.aiMessage = nil }
        }
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
            return item.name.caseInsensitiveCompare(name) == .orderedSame && Geometry.distance(point, other) < 0.5
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

    private func updateAim() {
        let center = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
        // Prefer real detected floor, fall back to an estimate while the floor is still being found.
        let hit = raycast(from: center, target: .existingPlaneGeometry)
            ?? raycast(from: center, target: .estimatedPlane)

        guard let hit else {
            aimPoint = nil
            reticle.isHidden = true
            liveSegment?.removeFromParentNode()
            liveSegment = nil
            return
        }
        var point = SIMD3<Float>(hit.worldTransform.columns.3.x, hit.worldTransform.columns.3.y, hit.worldTransform.columns.3.z)
        if let first = corners.first { point.y = first.y }
        aimPoint = point
        reticle.simdPosition = point
        reticle.isHidden = false

        liveSegment?.removeFromParentNode()
        liveSegment = nil
        if let last = corners.last, simd_distance(last, point) > 0.01 {
            let segment = Self.makeSegment(from: last, to: point, color: .white)
            sceneView.scene.rootNode.addChildNode(segment)
            liveSegment = segment
        }
    }

    private func raycast(from point: CGPoint, target: ARRaycastQuery.Target) -> ARRaycastResult? {
        guard let query = sceneView.raycastQuery(from: point, allowing: target, alignment: .horizontal) else { return nil }
        return sceneView.session.raycast(query).first
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
        let length = simd_distance(a, b)
        let cylinder = SCNCylinder(radius: 0.005, height: CGFloat(length))
        cylinder.firstMaterial?.diffuse.contents = color
        cylinder.firstMaterial?.lightingModel = .constant
        let node = SCNNode(geometry: cylinder)
        node.simdPosition = (a + b) / 2
        if length > 0.0001 {
            node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(b - a))
        }
        return node
    }
}
