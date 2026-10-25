import ARKit
import SceneKit
import UIKit

/// The guided item scan, run once a room's corners are mapped.
///
/// 1. Ceiling height: the user aims the + at the top of a wall, where it meets the ceiling.
/// 2. Then a grid is laid over each wall, the ceiling and the floor. The part to scan glows
///    orange and pulses, and an arrow points to it when it is off screen. When the + is on an
///    orange square and the phone is held still, a photo is taken on its own and sent to the
///    AI. Squares in view turn blue while the AI looks and green when it is done.
extension CornerMeasureController {
    enum ScanTarget: Hashable {
        case wall(Int)
        case ceiling
        case floor

        var label: String {
            switch self {
            case .wall(let index): return "Wall \(index + 1)"
            case .ceiling: return "Ceiling"
            case .floor: return "Floor"
            }
        }
    }

    enum SampleState {
        case pending
        case scanning
        case done
    }

    /// One square of the scan grid.
    struct ScanCell {
        let center: SIMD3<Float>
        /// Points out of the surface, into the room.
        let normal: SIMD3<Float>
        let node: SCNNode
        var state: SampleState = .pending
    }

    /// How fast the phone is turning and moving, smoothed over the last few frames.
    struct MotionTracker {
        private var lastTransform: simd_float4x4?
        private var lastTime: TimeInterval = 0
        private(set) var angularSpeed: Float = 0
        private(set) var linearSpeed: Float = 0
        var steadySince: TimeInterval?

        var isSteady: Bool { angularSpeed < 0.3 && linearSpeed < 0.2 }
        var isTooFast: Bool { angularSpeed > 0.9 || linearSpeed > 0.6 }

        func steadyTime(at time: TimeInterval) -> TimeInterval {
            steadySince.map { time - $0 } ?? 0
        }

        mutating func update(_ transform: simd_float4x4, at time: TimeInterval) {
            defer {
                lastTransform = transform
                lastTime = time
            }
            guard let last = lastTransform else { return }
            let dt = Float(time - lastTime)
            guard dt > 0.001, dt < 0.5 else { return }
            let before = simd_normalize(-SIMD3<Float>(last.columns.2.x, last.columns.2.y, last.columns.2.z))
            let after = simd_normalize(-SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
            let angle = acos(min(max(simd_dot(before, after), -1), 1))
            let moved = simd_distance(SIMD3<Float>(last.columns.3.x, last.columns.3.y, last.columns.3.z),
                                      SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z))
            angularSpeed = angularSpeed * 0.8 + angle / dt * 0.2
            linearSpeed = linearSpeed * 0.8 + moved / dt * 0.2
            if isSteady {
                if steadySince == nil { steadySince = time }
            } else {
                steadySince = nil
            }
        }
    }

    static let defaultCeilingHeight: Float = 2.44
    private static let cellSize: Float = 0.6

    var currentTarget: ScanTarget? {
        targetIndex < scanTargets.count ? scanTargets[targetIndex] : nil
    }

    /// Every part has been photographed and the AI has answered.
    var itemScanComplete: Bool {
        itemScanActive && currentTarget == nil && pendingRequests == 0
    }

    /// Share of a target that has been photographed, from 0 to 1.
    func coverage(of target: ScanTarget) -> Double {
        guard let cells = scanCells[target], !cells.isEmpty else { return 0 }
        return Double(cells.filter { $0.state != .pending }.count) / Double(cells.count)
    }

    private var roomHeight: Float { ceilingHeight ?? Self.defaultCeilingHeight }

    // MARK: Starting and stopping

    /// Starts the scan of a room whose corners are mapped, beginning with its ceiling height.
    /// Returns false if the room does not have enough corners yet.
    @discardableResult
    func startItemScan(roomName: String) -> Bool {
        guard corners.count >= 3 else { return false }
        removeScanNodes()
        scanRoomName = roomName
        scanSession = UUID()
        scanTargets = []
        targetIndex = 0
        targetsDone = []
        itemScanActive = true
        measuringCeiling = ceilingHeight == nil
        if !measuringCeiling { buildGrids() }
        motion.steadySince = nil
        return true
    }

    /// Saves the ceiling height under the + (or the given one) and lays out the scan grids.
    func confirmCeilingHeight(_ height: Float? = nil) {
        if let height {
            ceilingHeight = height
        } else if let live = liveCeilingHeight {
            ceilingHeight = live
        }
        measuringCeiling = false
        liveCeilingHeight = nil
        pointerNode.isHidden = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        buildGrids()
    }

    /// Lays out the scan grids without a measured ceiling height (a standard 8 ft is assumed).
    func skipCeilingHeight() {
        measuringCeiling = false
        liveCeilingHeight = nil
        pointerNode.isHidden = true
        buildGrids()
    }

    /// Ends the guided scan. Answers still on their way for it are ignored.
    func stopItemScan() {
        removeScanNodes()
        itemScanActive = false
        measuringCeiling = false
        liveCeilingHeight = nil
        scanTargets = []
        targetIndex = 0
        targetsDone = []
        scanCells = [:]
        scanSession = UUID()
        scanGuidance = ""
        turnAngle = nil
        pointerNode.isHidden = true
    }

    /// Moves on from the current target without photographing the rest of it.
    func skipCurrentTarget() {
        guard let target = currentTarget, var cells = scanCells[target] else { return }
        for index in cells.indices where cells[index].state == .pending { cells[index].state = .done }
        scanCells[target] = cells
        targetsDone.insert(target)
        advanceTarget()
    }

    /// Takes a photo of what is on screen right away, without waiting for the phone to be still.
    func captureNow() {
        guard itemScanActive, !measuringCeiling, let frame = sceneView.session.currentFrame,
              let target = currentTarget else { return }
        capture(target, cells: visiblePendingCells(of: target, in: frame), frame: frame)
    }

    private func removeScanNodes() {
        targetNodes.values.forEach { $0.removeFromParentNode() }
        targetNodes = [:]
    }

    // MARK: Grids

    private func buildGrids() {
        removeScanNodes()
        scanCells = [:]
        let floor = corners[0].y
        let height = roomHeight

        for index in corners.indices {
            let (a, b) = wallEnds(index)
            let length = simd_distance(a, b)
            let along = simd_normalize(b - a)
            let normal = inwardNormal(ofWall: index)
            let columns = max(1, Int((length / Self.cellSize).rounded()))
            let rows = max(2, Int((height / Self.cellSize).rounded()))
            let width = length / Float(columns)
            let tall = height / Float(rows)
            let rotation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: normal)
            var cells: [ScanCell] = []
            let container = SCNNode()
            for column in 0..<columns {
                for row in 0..<rows {
                    var center = a + along * (width * (Float(column) + 0.5)) + normal * 0.02
                    center.y = floor + tall * (Float(row) + 0.5)
                    let node = Self.makeCell(width: width, height: tall)
                    node.simdPosition = center
                    node.simdOrientation = Self.wallOrientation(along: along, normal: normal, fallback: rotation)
                    container.addChildNode(node)
                    cells.append(ScanCell(center: center, normal: normal, node: node))
                }
            }
            add(container, cells: cells, for: .wall(index))
        }

        for target in [ScanTarget.ceiling, .floor] {
            let y = target == .ceiling ? floor + height - 0.02 : floor + 0.02
            let normal = SIMD3<Float>(0, target == .ceiling ? -1 : 1, 0)
            let outline = corners.map(Self.floorPoint)
            guard let bounds = Geometry.bounds(of: outline) else { continue }
            var cells: [ScanCell] = []
            let container = SCNNode()
            let size = Double(Self.cellSize) * 1.2
            var x = bounds.minX + size / 2
            while x < bounds.maxX {
                var z = bounds.minY + size / 2
                while z < bounds.maxY {
                    if Geometry.contains(outline, Point2D(x: x, y: z)) {
                        let center = SIMD3<Float>(Float(x), y, Float(z))
                        let node = Self.makeCell(width: Float(size), height: Float(size))
                        node.simdPosition = center
                        node.simdOrientation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
                        container.addChildNode(node)
                        cells.append(ScanCell(center: center, normal: normal, node: node))
                    }
                    z += size
                }
                x += size
            }
            // A room smaller than one square still gets one in its middle.
            if cells.isEmpty, let middle = Geometry.center(of: outline) {
                let center = SIMD3<Float>(Float(middle.x), y, Float(middle.y))
                let node = Self.makeCell(width: Float(size), height: Float(size))
                node.simdPosition = center
                node.simdOrientation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
                container.addChildNode(node)
                cells.append(ScanCell(center: center, normal: normal, node: node))
            }
            add(container, cells: cells, for: target)
        }

        scanTargets = corners.indices.map { ScanTarget.wall($0) } + [.ceiling, .floor]
        targetIndex = 0
        refreshCells()
    }

    private func add(_ container: SCNNode, cells: [ScanCell], for target: ScanTarget) {
        sceneView.scene.rootNode.addChildNode(container)
        targetNodes[target] = container
        scanCells[target] = cells
    }

    /// Turns a flat square (facing +z) to lie on a wall, with its sides level.
    private static func wallOrientation(along: SIMD3<Float>, normal: SIMD3<Float>, fallback: simd_quatf) -> simd_quatf {
        let up = SIMD3<Float>(0, 1, 0)
        let x = simd_normalize(SIMD3<Float>(along.x, 0, along.z))
        let z = simd_normalize(simd_cross(x, up))
        let facing = simd_dot(z, normal) >= 0 ? z : -z
        let right = simd_cross(up, facing)
        let matrix = simd_float3x3(columns: (right, up, facing))
        let quaternion = simd_quatf(matrix)
        return quaternion.vector.x.isNaN ? fallback : quaternion
    }

    // MARK: Every frame

    func updateItemScan() {
        guard let frame = sceneView.session.currentFrame else { return }
        let now = frame.timestamp
        motion.update(frame.camera.transform, at: now)
        guard itemScanActive else {
            if movingTooFast { movingTooFast = false }
            return
        }

        let camera = frame.camera.transform
        let origin = SIMD3<Float>(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let forward = simd_normalize(-SIMD3<Float>(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z))

        if measuringCeiling {
            updateCeilingMeasure(origin: origin, forward: forward)
            return
        }

        let ready = trackingIsNormal && motion.isSteady && motion.steadyTime(at: now) > 0.5 && pendingRequests < 3
        var guidance: String
        var capturing: (ScanTarget, [Int])?
        var angle: Double?

        if let target = currentTarget {
            let name = target == .ceiling ? "the ceiling" : target == .floor ? "the floor" : target.label
            let aimed = pointedCell(of: target, origin: origin, forward: forward)
            if let aimed {
                showPointer(at: aimed.point, normal: aimed.normal, state: scanCells[target]?[aimed.cell].state)
            } else {
                pointerNode.isHidden = true
            }

            let visible = visiblePendingCells(of: target, in: frame)
            if let aimed, scanCells[target]?[aimed.cell].state == .pending {
                if distance(to: target, from: origin) < 0.9 {
                    guidance = "Step back from \(name) so more of it fits on screen."
                } else if ready {
                    guidance = "Got it…"
                    capturing = (target, Array(Set(visible + [aimed.cell])))
                } else {
                    guidance = "Hold still on \(name)…"
                }
            } else if !visible.isEmpty {
                guidance = "Move the + onto an orange square of \(name)."
            } else {
                guidance = target == .ceiling
                    ? "Tilt the phone up at the ceiling and put the + on an orange square."
                    : target == .floor
                    ? "Point the phone down at the floor and put the + on an orange square."
                    : "Turn to \(name), the one glowing orange, and put the + on it."
                angle = screenDirection(toward: target, camera: camera)
            }
        } else {
            pointerNode.isHidden = true
            guidance = pendingRequests > 0
                ? "Almost done. The AI is looking at the last photos…"
                : "This room is done. Tap Next Room, or Done if it was the last room."
        }

        let tooFast = motion.isTooFast
        if tooFast, currentTarget != nil {
            guidance = "Slow down. The AI needs a steady, sharp picture."
        }
        if tooFast != movingTooFast { movingTooFast = tooFast }
        if guidance != scanGuidance { scanGuidance = guidance }
        let roundedAngle = angle.map { ($0 * 12).rounded() / 12 }
        if roundedAngle != turnAngle { turnAngle = roundedAngle }

        if let capturing {
            capture(capturing.0, cells: capturing.1, frame: frame)
        }
    }

    /// Ceiling height: the + is aimed at the top of a wall, where it meets the ceiling.
    private func updateCeilingMeasure(origin: SIMD3<Float>, forward: SIMD3<Float>) {
        let floor = corners[0].y
        var best: (point: SIMD3<Float>, distance: Float, wall: Int)?
        for index in corners.indices {
            guard let hit = wallHit((origin, forward), wall: index), hit.along > -0.05, hit.along < 1.05 else { continue }
            if best == nil || hit.distance < best!.distance {
                best = (origin + forward * hit.distance, hit.distance, index)
            }
        }
        var guidance = "Aim the + at the top of a wall, right where it meets the ceiling."
        if let best, best.point.y - floor > 1.5, best.point.y - floor < 6 {
            let height = best.point.y - floor
            showPointer(at: best.point, normal: inwardNormal(ofWall: best.wall), state: nil)
            if liveCeilingHeight.map({ abs($0 - height) > 0.005 }) ?? true { liveCeilingHeight = height }
            guidance = "Put the + exactly where the wall meets the ceiling, then tap Set Ceiling Height."
        } else {
            pointerNode.isHidden = true
            if liveCeilingHeight != nil { liveCeilingHeight = nil }
            if let best, best.point.y - floor <= 1.5 { guidance = "Tilt up to the top of the wall, where it meets the ceiling." }
        }
        if guidance != scanGuidance { scanGuidance = guidance }
        if movingTooFast { movingTooFast = false }
    }

    // MARK: Pointer

    /// The square under the + on the given target, and where the + meets it.
    private func pointedCell(of target: ScanTarget, origin: SIMD3<Float>, forward: SIMD3<Float>)
        -> (cell: Int, point: SIMD3<Float>, normal: SIMD3<Float>)? {
        guard let cells = scanCells[target], !cells.isEmpty else { return nil }
        let floor = corners[0].y
        let point: SIMD3<Float>
        let normal: SIMD3<Float>
        switch target {
        case .wall(let index):
            guard let hit = wallHit((origin, forward), wall: index), hit.along > -0.02, hit.along < 1.02 else { return nil }
            point = origin + forward * hit.distance
            guard point.y > floor - 0.05, point.y < floor + roomHeight + 0.05 else { return nil }
            normal = inwardNormal(ofWall: index)
        case .ceiling, .floor:
            let y = target == .ceiling ? floor + roomHeight : floor
            guard abs(forward.y) > 0.05 else { return nil }
            let distance = (y - origin.y) / forward.y
            guard distance > 0.1, distance < 15 else { return nil }
            point = origin + forward * distance
            guard Geometry.isInside(corners.map(Self.floorPoint), Self.floorPoint(point), margin: 0.1) else { return nil }
            normal = SIMD3<Float>(0, target == .ceiling ? -1 : 1, 0)
        }
        let nearest = cells.indices.min { simd_distance(cells[$0].center, point) < simd_distance(cells[$1].center, point) }
        return nearest.map { ($0, point, normal) }
    }

    private func showPointer(at point: SIMD3<Float>, normal: SIMD3<Float>, state: SampleState?) {
        pointerNode.simdPosition = point + normal * 0.03
        pointerNode.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(normal))
        let color: UIColor
        switch state {
        case .pending?: color = .systemOrange
        case .scanning?: color = .systemBlue
        case .done?: color = .systemGreen
        case nil: color = .white
        }
        pointerNode.childNodes.first?.geometry?.firstMaterial?.diffuse.contents = color
        pointerNode.geometry?.firstMaterial?.diffuse.contents = color
        pointerNode.isHidden = false
    }

    /// Direction on screen to turn toward a target that is out of view: 0 is right, π/2 is up.
    private func screenDirection(toward target: ScanTarget, camera: simd_float4x4) -> Double? {
        guard let cells = scanCells[target]?.filter({ $0.state == .pending }), !cells.isEmpty else { return nil }
        let center = cells.map(\.center).reduce(SIMD3<Float>(repeating: 0), +) / Float(cells.count)
        let origin = SIMD3<Float>(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let direction = simd_normalize(center - origin)
        // Held upright, the camera's +y axis points to the right of the screen and -x points up.
        let right = SIMD3<Float>(camera.columns.1.x, camera.columns.1.y, camera.columns.1.z)
        let up = -SIMD3<Float>(camera.columns.0.x, camera.columns.0.y, camera.columns.0.z)
        let dx = simd_dot(direction, right)
        let dy = simd_dot(direction, up)
        guard abs(dx) + abs(dy) > 0.01 else { return nil }
        return Double(atan2(dy, dx))
    }

    // MARK: Capturing

    private func capture(_ target: ScanTarget, cells: [Int], frame: ARFrame) {
        guard let photo = FramePhoto(frame: frame) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        motion.steadySince = nil
        setState(.scanning, cells: cells, of: target, onlyIf: .pending)
        pendingRequests += 1
        advanceTarget()

        let session = scanSession
        let roomName = scanRoomName
        let focus = DetectionPresets.shared.activeFocus
        Task { @MainActor [weak self] in
            let result: Result<[DetectedItem], Error>
            do {
                result = .success(try await ItemDetector.detectItems(inJPEG: photo.jpeg, roomName: roomName, focus: focus))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.pendingRequests -= 1
            guard session == self.scanSession else { return }
            self.finishCapture(target, cells: cells, photo: photo, result: result)
        }
    }

    private func finishCapture(_ target: ScanTarget, cells: [Int], photo: FramePhoto, result: Result<[DetectedItem], Error>) {
        switch result {
        case .success(let detected):
            setState(.done, cells: cells, of: target, onlyIf: .scanning)
            if scanCells[target]?.allSatisfy({ $0.state == .done }) == true { targetsDone.insert(target) }
            let added = addDetected(detected, from: photo)
            aiScansThisRoom += 1
            lastAIAdded = added
            aiMessage = added.isEmpty
                ? "\(target.label): nothing new."
                : "\(target.label): added \(added.count) item\(added.count == 1 ? "" : "s")."
            if itemScanComplete {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                aiMessage = "Room scanned. \(items.count) items found."
            }
        case .failure(let error):
            setState(.pending, cells: cells, of: target, onlyIf: .scanning)
            advanceTarget()
            lastAIAdded = []
            aiMessage = error.localizedDescription
            if case .missingKey? = error as? ItemDetectorError { stopItemScan() }
        }
        refreshCells()
    }

    private func setState(_ state: SampleState, cells indices: [Int], of target: ScanTarget, onlyIf current: SampleState) {
        guard var cells = scanCells[target] else { return }
        for index in indices where cells.indices.contains(index) && cells[index].state == current {
            cells[index].state = state
        }
        scanCells[target] = cells
        refreshCells()
    }

    /// Adds what the AI found, leaving out anything outside this room, and draws doors and
    /// windows on the room's walls. Returns the items added.
    private func addDetected(_ detected: [DetectedItem], from photo: FramePhoto) -> [RoomItem] {
        var added: [RoomItem] = []
        for found in detected {
            if let kind = found.openingKind { addOpening(kind, for: found, from: photo) }
            let position = photo.worldPosition(x: found.x, y: found.y, in: sceneView.session,
                                               floorY: floorY, ceilingHeight: roomHeight)
            if let position, !Geometry.isInside(corners.map(Self.floorPoint), Self.floorPoint(position), margin: 0.4) {
                continue
            }
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
            added.append(item)
        }
        return added
    }

    /// The next target that still has squares to photograph.
    private func advanceTarget() {
        let previous = currentTarget
        targetIndex = scanTargets.firstIndex { scanCells[$0]?.contains { $0.state == .pending } ?? false } ?? scanTargets.count
        if previous != nil, currentTarget != previous {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        refreshCells()
    }

    // MARK: Geometry

    func wallEnds(_ index: Int) -> (SIMD3<Float>, SIMD3<Float>) {
        (corners[index], corners[(index + 1) % corners.count])
    }

    /// Direction pointing from a wall into the room, along the floor.
    func inwardNormal(ofWall index: Int) -> SIMD3<Float> {
        let (a, b) = wallEnds(index)
        let direction = simd_normalize(SIMD3<Float>(b.x - a.x, 0, b.z - a.z))
        var normal = SIMD3<Float>(-direction.z, 0, direction.x)
        let center = corners.reduce(SIMD3<Float>(repeating: 0), +) / Float(corners.count)
        let middle = (a + b) / 2
        if simd_dot(normal, SIMD3<Float>(center.x - middle.x, 0, center.z - middle.z)) < 0 { normal = -normal }
        return normal
    }

    private func distance(to target: ScanTarget, from origin: SIMD3<Float>) -> Float {
        switch target {
        case .wall(let index):
            let (a, _) = wallEnds(index)
            return abs(simd_dot(SIMD3<Float>(origin.x - a.x, 0, origin.z - a.z), inwardNormal(ofWall: index)))
        case .ceiling:
            return abs(corners[0].y + roomHeight - origin.y)
        case .floor:
            return abs(origin.y - corners[0].y)
        }
    }

    /// Squares not yet photographed that are on screen now and seen from the front.
    private func visiblePendingCells(of target: ScanTarget, in frame: ARFrame) -> [Int] {
        guard let cells = scanCells[target] else { return [] }
        let camera = frame.camera.transform
        let position = SIMD3<Float>(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let forward = simd_normalize(-SIMD3<Float>(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z))
        let resolution = frame.camera.imageResolution
        let viewport = CGSize(width: resolution.height, height: resolution.width)

        return cells.indices.filter { index in
            let cell = cells[index]
            guard cell.state == .pending else { return false }
            let toCell = cell.center - position
            guard simd_dot(forward, toCell) > 0.3 else { return false }
            guard simd_dot(simd_normalize(-toCell), cell.normal) > 0.25 else { return false }
            let projected = frame.camera.projectPoint(cell.center, orientation: .portrait, viewportSize: viewport)
            return projected.x > viewport.width * 0.08 && projected.x < viewport.width * 0.92
                && projected.y > viewport.height * 0.08 && projected.y < viewport.height * 0.92
        }
    }

    /// Where a line of sight meets a wall's vertical plane: how far along the wall (0 to 1 between
    /// its corners) and how far from the camera.
    func wallHit(_ ray: (origin: SIMD3<Float>, direction: SIMD3<Float>), wall index: Int) -> (along: Float, distance: Float)? {
        let (a, b) = wallEnds(index)
        let normal = inwardNormal(ofWall: index)
        let facing = simd_dot(ray.direction, normal)
        guard abs(facing) > 0.05 else { return nil }
        let distance = simd_dot(a - ray.origin, normal) / facing
        guard distance > 0.1 else { return nil }
        let hit = ray.origin + ray.direction * distance
        let wall = b - a
        let along = simd_dot(SIMD3<Float>(hit.x - a.x, 0, hit.z - a.z), SIMD3<Float>(wall.x, 0, wall.z))
            / max(simd_length_squared(SIMD3<Float>(wall.x, 0, wall.z)), 0.0001)
        return (along, distance)
    }

    /// The nearest mapped wall along a line of sight, for the measure tool.
    func nearestWallPoint(origin: SIMD3<Float>, direction: SIMD3<Float>) -> SIMD3<Float>? {
        guard corners.count >= 3 else { return nil }
        var best: Float?
        for index in corners.indices {
            guard let hit = wallHit((origin, direction), wall: index), hit.along >= 0, hit.along <= 1 else { continue }
            if best == nil || hit.distance < best! { best = hit.distance }
        }
        return best.map { origin + direction * $0 }
    }

    // MARK: Doors and windows

    /// Places a door, window or opening on the wall it is in, from the left and right edges of
    /// its box in the photo.
    private func addOpening(_ kind: OpeningKind, for found: DetectedItem, from photo: FramePhoto) {
        let middleY = (found.top + found.bottom) / 2
        let left = photo.ray(x: min(found.left, found.right), y: middleY)
        let right = photo.ray(x: max(found.left, found.right), y: middleY)

        // The wall the left edge's line of sight reaches first.
        var best: (wall: Int, distance: Float)?
        for index in corners.indices {
            guard let hit = wallHit(left, wall: index), hit.along > -0.15, hit.along < 1.15 else { continue }
            if best == nil || hit.distance < best!.distance { best = (index, hit.distance) }
        }
        guard let wall = best?.wall,
              let start = wallHit(left, wall: wall), let end = wallHit(right, wall: wall) else { return }
        let (a, b) = wallEnds(wall)
        let t0 = min(max(min(start.along, end.along), 0), 1)
        let t1 = min(max(max(start.along, end.along), 0), 1)
        guard (t1 - t0) * simd_distance(a, b) > 0.3 else { return }

        let p0 = Self.floorPoint(a + (b - a) * t0)
        let p1 = Self.floorPoint(a + (b - a) * t1)
        // Seen before from another photo.
        if openings.contains(where: { Geometry.distance(from: Geometry.midpoint($0.start, $0.end), toSegment: p0, p1) < 0.3 }) {
            return
        }
        openings.append(Opening(kind: kind, start: p0, end: p1))
    }

    // MARK: Look

    /// Colors every square by its state. The target to scan pulses so it stands out.
    func refreshCells() {
        let current = currentTarget
        for (target, cells) in scanCells {
            let isCurrent = target == current
            for cell in cells {
                cell.node.geometry?.firstMaterial?.diffuse.contents = Self.cellImage(cell.state, current: isCurrent)
            }
            guard let container = targetNodes[target] else { continue }
            if isCurrent {
                if container.action(forKey: "pulse") == nil {
                    let pulse = SCNAction.repeatForever(.sequence([
                        .fadeOpacity(to: 0.55, duration: 0.6),
                        .fadeOpacity(to: 1, duration: 0.6),
                    ]))
                    container.runAction(pulse, forKey: "pulse")
                }
            } else {
                container.removeAction(forKey: "pulse")
                container.opacity = 1
            }
        }
    }

    private static func makeCell(width: Float, height: Float) -> SCNNode {
        let plane = SCNPlane(width: CGFloat(width * 0.92), height: CGFloat(height * 0.92))
        plane.cornerRadius = CGFloat(min(width, height) * 0.08)
        let material = plane.firstMaterial
        material?.lightingModel = .constant
        material?.isDoubleSided = true
        material?.writesToDepthBuffer = false
        return SCNNode(geometry: plane)
    }

    /// A square with a bright border, so the grid reads clearly over any wall color.
    private static func cellImage(_ state: SampleState, current: Bool) -> UIImage {
        let key = "\(state)-\(current)"
        if let cached = cellImages[key] { return cached }
        let color: UIColor
        let fill: CGFloat
        switch state {
        case .done: color = .systemGreen; fill = 0.35
        case .scanning: color = .systemBlue; fill = 0.45
        case .pending: color = current ? .systemOrange : .white; fill = current ? 0.4 : 0.06
        }
        let size = CGSize(width: 64, height: 64)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 8)
            color.withAlphaComponent(fill).setFill()
            path.fill()
            color.withAlphaComponent(current || state != .pending ? 1 : 0.35).setStroke()
            path.lineWidth = current ? 5 : 3
            path.stroke()
        }
        cellImages[key] = image
        return image
    }
}

/// Square images for the scan grid, made once per look.
private var cellImages: [String: UIImage] = [:]
