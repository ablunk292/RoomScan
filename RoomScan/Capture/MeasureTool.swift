import ARKit
import SceneKit
import UIKit

/// Tape measure in AR: aim the + at a spot, tap Set Point, aim at a second spot and tap again.
/// Works on floors, walls and furniture. Used while mapping a room and on its own from a
/// room's page. The owner calls `update()` once per frame while it is showing.
final class MeasureTool: ObservableObject {
    /// Distance from the first point to the + (or the finished length), in meters.
    @Published private(set) var liveLength: Double?
    @Published private(set) var hasStart = false
    /// A finished two-point measurement waiting for a name.
    @Published var finishedLength: Double?
    @Published private(set) var isAimed = false

    private let sceneView: ARSCNView
    /// Extra surfaces to aim at, such as the walls of a mapped room. Returns a point on the
    /// line of sight, or nil.
    var extraSurfaces: ((SIMD3<Float>, SIMD3<Float>) -> SIMD3<Float>?)?
    /// Height of the floor, if known, used when nothing else is under the +.
    var floorY: (() -> Float?)?

    private let root = SCNNode()
    private let pointer = MeasureTool.makeDot(radius: 0.012, color: .white)
    private let startDot = MeasureTool.makeDot(radius: 0.015, color: .systemYellow)
    private let endDot = MeasureTool.makeDot(radius: 0.015, color: .systemYellow)
    private let line = MeasureTool.makeLine()
    private var start: SIMD3<Float>?
    private var smoothed: SIMD3<Float>?
    private var lastPublish: CFTimeInterval = 0

    var isShowing = false {
        didSet {
            root.isHidden = !isShowing
            if !isShowing { clear() }
        }
    }

    init(sceneView: ARSCNView) {
        self.sceneView = sceneView
        for node in [pointer, startDot, endDot, line] { root.addChildNode(node) }
        root.isHidden = true
        sceneView.scene.rootNode.addChildNode(root)
        clear()
    }

    func setPoint() {
        guard let point = smoothed else { return }
        if let start {
            endDot.simdPosition = point
            endDot.isHidden = false
            Self.place(line, from: start, to: point)
            finishedLength = Double(simd_distance(start, point))
            liveLength = finishedLength
            self.start = nil
            hasStart = false
        } else {
            clear()
            start = point
            startDot.simdPosition = point
            startDot.isHidden = false
            hasStart = true
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func clear() {
        start = nil
        hasStart = false
        liveLength = nil
        startDot.isHidden = true
        endDot.isHidden = true
        line.isHidden = true
    }

    func update() {
        guard isShowing, let frame = sceneView.session.currentFrame else { return }
        let camera = frame.camera.transform
        let origin = SIMD3<Float>(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let forward = simd_normalize(-SIMD3<Float>(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z))

        guard let target = hit(origin: origin, direction: forward) else {
            pointer.isHidden = true
            if isAimed { isAimed = false }
            return
        }
        if let previous = smoothed, simd_distance(previous, target) < 0.3 {
            smoothed = simd_mix(previous, target, SIMD3<Float>(repeating: 0.35))
        } else {
            smoothed = target
        }
        guard let point = smoothed else { return }
        pointer.simdPosition = point
        pointer.isHidden = false
        if !isAimed { isAimed = true }

        if let start {
            Self.place(line, from: start, to: point)
            line.isHidden = false
            let now = CACurrentMediaTime()
            if now - lastPublish > 0.1 {
                liveLength = Double(simd_distance(start, point))
                lastPublish = now
            }
        }
    }

    /// The nearest surface along the line of sight: a detected surface, a mapped wall, or the floor.
    private func hit(origin: SIMD3<Float>, direction: SIMD3<Float>) -> SIMD3<Float>? {
        var candidates: [SIMD3<Float>] = []
        for target in [ARRaycastQuery.Target.existingPlaneGeometry, .estimatedPlane] {
            let query = ARRaycastQuery(origin: origin, direction: direction, allowing: target, alignment: .any)
            if let result = sceneView.session.raycast(query).first {
                let t = result.worldTransform.columns.3
                candidates.append(SIMD3<Float>(t.x, t.y, t.z))
                break
            }
        }
        if let point = extraSurfaces?(origin, direction) { candidates.append(point) }
        if let floor = floorY?(), direction.y < -0.05 {
            let distance = (floor - origin.y) / direction.y
            if distance > 0, distance < 15 { candidates.append(origin + direction * distance) }
        }
        return candidates.min { simd_distance($0, origin) < simd_distance($1, origin) }
    }

    private static func makeDot(radius: CGFloat, color: UIColor) -> SCNNode {
        let sphere = SCNSphere(radius: radius)
        sphere.firstMaterial?.diffuse.contents = color
        sphere.firstMaterial?.lightingModel = .constant
        return SCNNode(geometry: sphere)
    }

    private static func makeLine() -> SCNNode {
        let cylinder = SCNCylinder(radius: 0.004, height: 0.01)
        cylinder.firstMaterial?.diffuse.contents = UIColor.systemYellow
        cylinder.firstMaterial?.lightingModel = .constant
        return SCNNode(geometry: cylinder)
    }

    private static func place(_ node: SCNNode, from a: SIMD3<Float>, to b: SIMD3<Float>) {
        let length = simd_distance(a, b)
        (node.geometry as? SCNCylinder)?.height = CGFloat(length)
        node.simdPosition = (a + b) / 2
        if length > 0.0001 {
            node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(b - a))
        }
    }
}
