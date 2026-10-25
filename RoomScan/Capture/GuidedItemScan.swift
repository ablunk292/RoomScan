import ARKit
import SceneKit
import UIKit

/// The guided item scan: once a room's corners are mapped, the app walks the user around the
/// room one wall at a time, then the ceiling and floor. The wall to point at glows orange.
/// Whenever the phone is held steady on a part of it that has not been photographed yet, a
/// photo is taken and sent to the AI on its own; that part turns blue while the AI looks and
/// green when it is done. No button presses are needed.
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

    private static let samplesPerMeter: Float = 3
    private static let panelHeight: Float = 2.0
    /// Height on the wall used to tell whether a part of it is in view.
    private static let viewHeight: Float = 1.1

    var currentTarget: ScanTarget? {
        targetIndex < scanTargets.count ? scanTargets[targetIndex] : nil
    }

    /// Every wall, the ceiling and the floor have been photographed and the AI has answered.
    var itemScanComplete: Bool {
        itemScanActive && currentTarget == nil && pendingRequests == 0
    }

    /// Share of a wall that has been photographed, from 0 to 1.
    func coverage(of target: ScanTarget) -> Double {
        switch target {
        case .wall(let index):
            guard index < wallSamples.count, !wallSamples[index].isEmpty else { return 0 }
            let covered = wallSamples[index].filter { $0 != .pending }.count
            return Double(covered) / Double(wallSamples[index].count)
        case .ceiling, .floor:
            return targetsDone.contains(target) || inFlight.contains(target) ? 1 : 0
        }
    }

    // MARK: Starting and stopping

    /// Starts the guided scan of the room whose corners are mapped. Returns false if the room
    /// does not have enough corners yet.
    @discardableResult
    func startItemScan(roomName: String) -> Bool {
        guard corners.count >= 3 else { return false }
        removeSampleNodes()
        scanRoomName = roomName
        scanSession = UUID()
        scanTargets = corners.indices.map { ScanTarget.wall($0) } + [.ceiling, .floor]
        targetIndex = 0
        targetsDone = []
        inFlight = []
        wallSamples = []
        sampleNodes = []

        let floor = corners[0].y
        for index in corners.indices {
            let (a, b) = wallEnds(index)
            let count = max(3, Int((simd_distance(a, b) * Self.samplesPerMeter).rounded(.up)))
            wallSamples.append(Array(repeating: .pending, count: count))
            var nodes: [SCNNode] = []
            for k in 0..<count {
                let p0 = a + (b - a) * (Float(k) / Float(count))
                let p1 = a + (b - a) * (Float(k + 1) / Float(count))
                let panel = SCNBox(width: CGFloat(simd_distance(p0, p1) * 0.94), height: CGFloat(Self.panelHeight),
                                   length: 0.004, chamferRadius: 0)
                panel.firstMaterial?.lightingModel = .constant
                panel.firstMaterial?.isDoubleSided = true
                let node = SCNNode(geometry: panel)
                let middle = (p0 + p1) / 2
                node.simdPosition = SIMD3<Float>(middle.x, floor + Self.panelHeight / 2, middle.z)
                let direction = b - a
                node.simdOrientation = simd_quatf(angle: atan2(-direction.z, direction.x), axis: SIMD3<Float>(0, 1, 0))
                sceneView.scene.rootNode.addChildNode(node)
                nodes.append(node)
            }
            sampleNodes.append(nodes)
        }
        itemScanActive = true
        motion.steadySince = nil
        refreshSampleColors()
        return true
    }

    /// Ends the guided scan. Answers still on their way for it are ignored.
    func stopItemScan() {
        removeSampleNodes()
        itemScanActive = false
        scanTargets = []
        targetIndex = 0
        targetsDone = []
        inFlight = []
        wallSamples = []
        scanSession = UUID()
        scanGuidance = ""
    }

    /// Moves on from the current target without photographing it.
    func skipCurrentTarget() {
        guard let target = currentTarget else { return }
        if case .wall(let index) = target {
            wallSamples[index] = wallSamples[index].map { $0 == .pending ? .done : $0 }
        }
        targetsDone.insert(target)
        advanceTarget()
        refreshSampleColors()
    }

    /// Takes a photo of the current target right away, without waiting for the phone to be still.
    func captureNow() {
        guard itemScanActive, let frame = sceneView.session.currentFrame, let target = currentTarget else { return }
        if case .wall(let index) = target {
            capture(target, samples: visiblePendingSamples(ofWall: index, in: frame), frame: frame)
        } else {
            capture(target, samples: [], frame: frame)
        }
    }

    private func removeSampleNodes() {
        sampleNodes.joined().forEach { $0.removeFromParentNode() }
        sampleNodes = []
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
        let forward = simd_normalize(-SIMD3<Float>(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z))
        let ready = trackingIsNormal && motion.isSteady && motion.steadyTime(at: now) > 0.6 && pendingRequests < 3
        var guidance: String
        var capturing: (ScanTarget, [Int])?

        switch currentTarget {
        case nil:
            guidance = pendingRequests > 0
                ? "Almost done. The AI is looking at the last photos…"
                : "This room is done. Tap Next Room, or Done if it was the last room."
        case .wall(let index)?:
            let name = ScanTarget.wall(index).label
            let visible = visiblePendingSamples(ofWall: index, in: frame)
            let remaining = wallSamples[index].filter { $0 == .pending }.count
            let needed = min(remaining, max(2, wallSamples[index].count / 4))
            if visible.isEmpty {
                guidance = "Turn to \(name), the one glowing orange, and point the phone at it."
            } else if distance(toWall: index, from: camera) < 0.9 {
                guidance = "Step back from \(name) so more of it fits on screen."
            } else if visible.count < needed {
                guidance = "Turn a little to show more of the orange part of \(name)."
            } else if ready {
                guidance = "Got it…"
                capturing = (.wall(index), visible)
            } else {
                guidance = "Hold still on \(name)…"
            }
        case .ceiling?:
            if forward.y < 0.55 {
                guidance = "Now tilt the phone up at the ceiling, for lights, vents and detectors."
            } else if ready {
                guidance = "Got it…"
                capturing = (.ceiling, [])
            } else {
                guidance = "Hold still on the ceiling…"
            }
        case .floor?:
            if forward.y > -0.7 {
                guidance = "Last one: point the phone down at the floor in front of you."
            } else if ready {
                guidance = "Got it…"
                capturing = (.floor, [])
            } else {
                guidance = "Hold still on the floor…"
            }
        }

        let tooFast = motion.isTooFast
        if tooFast, currentTarget != nil {
            guidance = "Slow down. The AI needs a steady, sharp picture."
        }
        if tooFast != movingTooFast { movingTooFast = tooFast }
        if guidance != scanGuidance { scanGuidance = guidance }

        if let capturing {
            capture(capturing.0, samples: capturing.1, frame: frame)
        }
    }

    // MARK: Capturing

    private func capture(_ target: ScanTarget, samples: [Int], frame: ARFrame) {
        guard let photo = FramePhoto(frame: frame) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        motion.steadySince = nil

        switch target {
        case .wall(let index):
            for k in samples { wallSamples[index][k] = .scanning }
        case .ceiling, .floor:
            inFlight.insert(target)
        }
        pendingRequests += 1
        advanceTarget()
        refreshSampleColors()

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
            self.finishCapture(target, samples: samples, photo: photo, result: result)
        }
    }

    private func finishCapture(_ target: ScanTarget, samples: [Int], photo: FramePhoto, result: Result<[DetectedItem], Error>) {
        switch result {
        case .success(let detected):
            switch target {
            case .wall(let index):
                for k in samples { wallSamples[index][k] = .done }
                if !wallSamples[index].contains(where: { $0 != .done }) { targetsDone.insert(target) }
            case .ceiling, .floor:
                inFlight.remove(target)
                targetsDone.insert(target)
            }
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
            switch target {
            case .wall(let index):
                for k in samples where wallSamples[index][k] == .scanning { wallSamples[index][k] = .pending }
            case .ceiling, .floor:
                inFlight.remove(target)
            }
            advanceTarget()
            lastAIAdded = []
            aiMessage = error.localizedDescription
            if case .missingKey? = error as? ItemDetectorError { stopItemScan() }
        }
        refreshSampleColors()
    }

    /// Adds what the AI found, leaving out anything outside this room, and draws doors and
    /// windows on the room's walls. Returns the items added.
    private func addDetected(_ detected: [DetectedItem], from photo: FramePhoto) -> [RoomItem] {
        var added: [RoomItem] = []
        for found in detected {
            if let kind = found.openingKind { addOpening(kind, for: found, from: photo) }
            let position = photo.worldPosition(x: found.x, y: found.y, in: sceneView.session, floorY: floorY)
            if let position, !isInsideRoom(Self.floorPoint(position)) { continue }
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

    /// The next target that still needs a photo.
    private func advanceTarget() {
        targetIndex = scanTargets.firstIndex { target in
            switch target {
            case .wall(let index): return wallSamples[index].contains(.pending)
            case .ceiling, .floor: return !targetsDone.contains(target) && !inFlight.contains(target)
            }
        } ?? scanTargets.count
    }

    // MARK: Walls

    func wallEnds(_ index: Int) -> (SIMD3<Float>, SIMD3<Float>) {
        (corners[index], corners[(index + 1) % corners.count])
    }

    /// Direction pointing from a wall into the room, along the floor.
    private func inwardNormal(ofWall index: Int) -> SIMD3<Float> {
        let (a, b) = wallEnds(index)
        let direction = simd_normalize(SIMD3<Float>(b.x - a.x, 0, b.z - a.z))
        var normal = SIMD3<Float>(-direction.z, 0, direction.x)
        let center = corners.reduce(SIMD3<Float>(repeating: 0), +) / Float(corners.count)
        let middle = (a + b) / 2
        if simd_dot(normal, SIMD3<Float>(center.x - middle.x, 0, center.z - middle.z)) < 0 { normal = -normal }
        return normal
    }

    private func distance(toWall index: Int, from camera: simd_float4x4) -> Float {
        let (a, _) = wallEnds(index)
        let position = SIMD3<Float>(camera.columns.3.x, a.y, camera.columns.3.z)
        return abs(simd_dot(position - a, inwardNormal(ofWall: index)))
    }

    /// Parts of a wall not yet photographed that are on screen now, seen from inside the room.
    private func visiblePendingSamples(ofWall index: Int, in frame: ARFrame) -> [Int] {
        let (a, b) = wallEnds(index)
        let camera = frame.camera.transform
        let position = SIMD3<Float>(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let forward = simd_normalize(-SIMD3<Float>(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z))
        let normal = inwardNormal(ofWall: index)
        let resolution = frame.camera.imageResolution
        let viewport = CGSize(width: resolution.height, height: resolution.width)
        let count = wallSamples[index].count

        return (0..<count).filter { k in
            guard wallSamples[index][k] == .pending else { return false }
            var point = a + (b - a) * ((Float(k) + 0.5) / Float(count))
            point.y = a.y + Self.viewHeight
            let toPoint = point - position
            guard simd_dot(forward, toPoint) > 0.3 else { return false }
            // Seen from inside the room, and not at too sharp an angle.
            let toCamera = simd_normalize(SIMD3<Float>(-toPoint.x, 0, -toPoint.z))
            guard simd_dot(toCamera, normal) > 0.3 else { return false }
            let projected = frame.camera.projectPoint(point, orientation: .portrait, viewportSize: viewport)
            return projected.x > viewport.width * 0.06 && projected.x < viewport.width * 0.94
                && projected.y > viewport.height * 0.1 && projected.y < viewport.height * 0.9
        }
    }

    /// Inside the room's outline, or within 40 cm of it (things on or in the walls).
    private func isInsideRoom(_ point: Point2D) -> Bool {
        Geometry.isInside(corners.map(Self.floorPoint), point, margin: 0.4)
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

    /// Where a line of sight meets a wall's vertical plane: how far along the wall (0 to 1 between
    /// its corners) and how far from the camera.
    private func wallHit(_ ray: (origin: SIMD3<Float>, direction: SIMD3<Float>), wall index: Int) -> (along: Float, distance: Float)? {
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

    // MARK: Colors

    func refreshSampleColors() {
        let current = currentTarget
        for (index, nodes) in sampleNodes.enumerated() {
            let isCurrent = current == .wall(index)
            for (k, node) in nodes.enumerated() {
                let color: UIColor
                switch wallSamples[index][k] {
                case .done: color = UIColor.systemGreen.withAlphaComponent(0.28)
                case .scanning: color = UIColor.systemBlue.withAlphaComponent(0.3)
                case .pending: color = isCurrent ? UIColor.systemOrange.withAlphaComponent(0.4) : UIColor.white.withAlphaComponent(0.08)
                }
                node.geometry?.firstMaterial?.diffuse.contents = color
            }
        }
    }
}
