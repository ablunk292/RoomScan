import ARKit
import Combine
import RoomPlan
import SwiftUI
import UIKit

/// Whole-room LiDAR scanning with Apple's RoomPlan. Only runs on phones and iPads with LiDAR.
/// Rooms scanned one after another share one AR session, so they line up into a floor plan.
struct LiDARScanScreen: UIViewControllerRepresentable {
    let firstRoomName: String
    let modelsDirectory: URL
    let onCancel: () -> Void
    let onFinish: ([Room]) -> Void

    func makeUIViewController(context: Context) -> LiDARScanViewController {
        let controller = LiDARScanViewController()
        controller.firstRoomName = firstRoomName
        controller.modelsDirectory = modelsDirectory
        controller.onCancel = onCancel
        controller.onFinish = onFinish
        return controller
    }

    func updateUIViewController(_ uiViewController: LiDARScanViewController, context: Context) {}
}

final class LiDARScanViewController: UIViewController, RoomCaptureViewDelegate {
    var firstRoomName = "Room 1"
    var modelsDirectory: URL!
    var onCancel: (() -> Void)?
    var onFinish: (([Room]) -> Void)?

    private enum Phase {
        case scanning
        case processing(thenFinish: Bool)
        case betweenRooms
    }

    private let arSession = ARSession()
    private var captureView: RoomCaptureView!
    private var phase = Phase.betweenRooms
    private var rooms: [Room] = []
    /// Items the AI found in the room being scanned; added to it once RoomPlan finishes the room.
    private var aiItems: [RoomItem] = []
    private var isAnalyzing = false

    private let cancelButton = UIButton(configuration: .gray())
    private let aiButton = UIButton(configuration: .gray())
    private let nextButton = UIButton(configuration: .gray())
    private let doneButton = UIButton(configuration: .filled())
    private let messageLabel = UILabel()
    private let focusButton = UIButton(configuration: .gray())
    private var focusWatch: AnyCancellable?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        captureView = RoomCaptureView(frame: view.bounds, arSession: arSession)
        captureView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        captureView.delegate = self
        view.addSubview(captureView)

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        aiButton.setTitle("AI Find Items", for: .normal)
        aiButton.setImage(UIImage(systemName: "sparkles"), for: .normal)
        aiButton.addTarget(self, action: #selector(aiTapped), for: .touchUpInside)
        nextButton.setTitle("Next Room", for: .normal)
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        doneButton.setTitle("Done", for: .normal)
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        focusButton.configuration?.buttonSize = .small
        focusButton.configuration?.cornerStyle = .capsule
        focusButton.configuration?.image = UIImage(systemName: "line.3.horizontal.decrease.circle")
        focusButton.configuration?.imagePadding = 6
        focusButton.addTarget(self, action: #selector(focusTapped), for: .touchUpInside)
        focusWatch = DetectionPresets.shared.$activeFocus.sink { [weak self] _ in
            // The published value changes just before it is stored, so read the name afterwards.
            DispatchQueue.main.async { self?.updateFocusTitle() }
        }

        messageLabel.textColor = .white
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        messageLabel.layer.cornerRadius = 8
        messageLabel.clipsToBounds = true
        messageLabel.isHidden = true

        let bottomRow = UIStackView(arrangedSubviews: [aiButton, nextButton, doneButton])
        bottomRow.axis = .horizontal
        bottomRow.spacing = 8
        bottomRow.distribution = .fillEqually

        for subview in [cancelButton, messageLabel, focusButton, bottomRow] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            cancelButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            cancelButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            messageLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            messageLabel.bottomAnchor.constraint(equalTo: focusButton.topAnchor, constant: -12),
            focusButton.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            focusButton.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 16),
            focusButton.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -10),
            bottomRow.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            bottomRow.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            bottomRow.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
            bottomRow.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if rooms.isEmpty, case .betweenRooms = phase { startRoom() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if case .scanning = phase { captureView.captureSession.stop() }
        arSession.pause()
    }

    private func startRoom() {
        aiItems = []
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        phase = .scanning
        updateButtons()
    }

    private func updateButtons() {
        switch phase {
        case .scanning:
            aiButton.isEnabled = !isAnalyzing
            nextButton.isEnabled = true
            nextButton.setTitle("Next Room", for: .normal)
            doneButton.isEnabled = true
            doneButton.setTitle("Done", for: .normal)
        case .processing:
            aiButton.isEnabled = false
            nextButton.isEnabled = false
            doneButton.isEnabled = false
            doneButton.setTitle("Processing…", for: .normal)
        case .betweenRooms:
            aiButton.isEnabled = false
            nextButton.isEnabled = true
            nextButton.setTitle("Scan Next Room", for: .normal)
            doneButton.isEnabled = !rooms.isEmpty
            doneButton.setTitle("Done", for: .normal)
        }
    }

    private func show(_ message: String) {
        messageLabel.text = "  \(message)  "
        messageLabel.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.messageLabel.text == "  \(message)  " { self?.messageLabel.isHidden = true }
        }
    }

    // MARK: Buttons

    private func updateFocusTitle() {
        focusButton.configuration?.title = "AI looks for: \(DetectionPresets.shared.activeName)"
        focusButton.configuration?.titleLineBreakMode = .byTruncatingTail
    }

    @objc private func focusTapped() {
        present(UIHostingController(rootView: AIFocusPicker()), animated: true)
    }

    @objc private func cancelTapped() {
        if case .scanning = phase { captureView.captureSession.stop() }
        (rooms.flatMap(\.items) + aiItems).forEach { ItemPhotos.delete($0.photoFileName) }
        onCancel?()
    }

    @objc private func nextTapped() {
        switch phase {
        case .scanning:
            stopRoom(thenFinish: false)
        case .betweenRooms:
            startRoom()
        case .processing:
            break
        }
    }

    @objc private func doneTapped() {
        switch phase {
        case .scanning:
            stopRoom(thenFinish: true)
        case .betweenRooms:
            onFinish?(rooms)
        case .processing:
            break
        }
    }

    private func stopRoom(thenFinish: Bool) {
        // Keep the AR session running so the next room shares its coordinates.
        captureView.captureSession.stop(pauseARSession: false)
        phase = .processing(thenFinish: thenFinish)
        updateButtons()
    }

    @objc private func aiTapped() {
        guard !isAnalyzing, let frame = arSession.currentFrame, let photo = FramePhoto(frame: frame) else { return }
        isAnalyzing = true
        aiButton.configuration?.showsActivityIndicator = true
        updateButtons()
        let roomName = currentRoomName
        let focus = DetectionPresets.shared.activeFocus
        Task { @MainActor in
            defer {
                isAnalyzing = false
                aiButton.configuration?.showsActivityIndicator = false
                updateButtons()
            }
            do {
                let found = try await ItemDetector.detectItems(inJPEG: photo.jpeg, roomName: roomName, focus: focus)
                var added = 0
                for detected in found {
                    let position = photo.worldPosition(x: detected.x, y: detected.y, in: arSession)
                        .map { Point2D(x: Double($0.x), y: Double($0.z)) }
                    let duplicate = aiItems.contains { item in
                        guard let position, let other = item.position else { return false }
                        return item.name.caseInsensitiveCompare(detected.name) == .orderedSame
                            && Geometry.distance(position, other) < 0.25
                    }
                    if duplicate { continue }
                    aiItems.append(RoomItem(
                        name: detected.name,
                        category: detected.category,
                        condition: detected.condition,
                        notes: detected.notes,
                        position: position,
                        detectedAutomatically: true,
                        photoFileName: photo.closeUp(of: detected).flatMap { ItemPhotos.save($0) }
                    ))
                    added += 1
                }
                show(CornerMeasureController.summary(found: found.count, added: added))
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    private var currentRoomName: String {
        rooms.isEmpty ? firstRoomName : "Room \(rooms.count + 1)"
    }

    // MARK: RoomCaptureViewDelegate

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        guard case .processing(let thenFinish) = phase else { return }
        if let error {
            show("This room could not be processed: \(error.localizedDescription)")
        } else {
            var room = CapturedRoomConverter.room(from: processedResult, named: currentRoomName)
            room.items += aiItems
            let fileName = "\(room.id.uuidString).usdz"
            do {
                try processedResult.export(to: modelsDirectory.appendingPathComponent(fileName), exportOptions: .parametric)
                room.modelFileName = fileName
            } catch {
                print("LiDAR scan: could not save 3D model: \(error)")
            }
            rooms.append(room)
        }
        aiItems = []
        if thenFinish, !rooms.isEmpty {
            onFinish?(rooms)
            return
        }
        phase = .betweenRooms
        updateButtons()
        show("\(rooms.count) room\(rooms.count == 1 ? "" : "s") saved. Walk to the next room and tap Scan Next Room, or Done.")
    }
}
