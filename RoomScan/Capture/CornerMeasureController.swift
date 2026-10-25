import ARKit
import SceneKit
import UIKit

/// Runs the AR session for measuring a room by tapping its floor corners.
/// Works on any iPhone with ARKit; it does not need LiDAR.
///
/// The crosshair in the middle of the screen is projected onto the floor every frame.
/// Corners and item pins are dropped where the crosshair meets the floor.
final class CornerMeasureController: NSObject, ObservableObject, ARSCNViewDelegate, ARSessionDelegate {
    struct PlacedItem {
        var name: String
        var position: SIMD3<Float>
    }

    @Published private(set) var corners: [SIMD3<Float>] = []
    @Published private(set) var items: [PlacedItem] = []
    @Published private(set) var aimPoint: SIMD3<Float>?
    @Published private(set) var status = "Move your phone slowly to find the floor."

    let sceneView = ARSCNView()

    private let reticle = CornerMeasureController.makeReticle()
    private var cornerNodes: [SCNNode] = []
    private var segmentNodes: [SCNNode] = []
    private var itemNodes: [SCNNode] = []
    private var liveSegment: SCNNode?
    private var closingSegment: SCNNode?
    private var updatePending = false

    /// Distance from the last corner to the crosshair, in meters.
    var liveDistance: Double? {
        guard let last = corners.last, let aim = aimPoint else { return nil }
        return Double(simd_distance(last, aim))
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

    // MARK: Actions

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

    func addItem(named name: String) {
        guard let point = aimPoint else { return }
        let node = Self.makeItemMarker()
        node.simdPosition = point
        sceneView.scene.rootNode.addChildNode(node)
        itemNodes.append(node)
        items.append(PlacedItem(name: name, position: point))
    }

    /// Builds the finished room. Floor coordinates are x and z of the AR world, seen from above.
    func makeRoom(named name: String) -> Room {
        let outline = corners.map { Point2D(x: Double($0.x), y: Double($0.z)) }
        let roomItems = items.map { item in
            RoomItem(name: item.name, position: Point2D(x: Double(item.position.x), y: Double(item.position.z)))
        }
        return Room(name: name, method: .cornerTap, outline: outline, items: roomItems)
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
            message = corners.isEmpty ? "Aim the crosshair at a floor corner and tap Add Corner." : "Aim at the next corner."
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

    /// Dashed-looking line from the last corner back to the first, so the user sees the room close.
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

    private static func makeItemMarker() -> SCNNode {
        let pin = SCNCylinder(radius: 0.01, height: 0.25)
        pin.firstMaterial?.diffuse.contents = UIColor.systemTeal
        pin.firstMaterial?.lightingModel = .constant
        let pinNode = SCNNode(geometry: pin)
        pinNode.simdPosition = SIMD3<Float>(0, 0.125, 0)
        let head = SCNSphere(radius: 0.03)
        head.firstMaterial?.diffuse.contents = UIColor.systemTeal
        head.firstMaterial?.lightingModel = .constant
        let headNode = SCNNode(geometry: head)
        headNode.simdPosition = SIMD3<Float>(0, 0.25, 0)
        let node = SCNNode()
        node.addChildNode(pinNode)
        node.addChildNode(headNode)
        return node
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
