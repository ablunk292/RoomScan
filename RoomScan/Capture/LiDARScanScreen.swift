import RoomPlan
import SwiftUI
import UIKit

/// Full-room LiDAR scan with Apple's RoomPlan. Only runs on phones and iPads with LiDAR.
struct LiDARScanScreen: UIViewControllerRepresentable {
    let roomName: String
    let modelsDirectory: URL
    let onCancel: () -> Void
    let onFinish: (Room) -> Void

    func makeUIViewController(context: Context) -> LiDARScanViewController {
        let controller = LiDARScanViewController()
        controller.onCancel = onCancel
        controller.onFinish = { captured in
            var room = CapturedRoomConverter.room(from: captured, named: roomName)
            let fileName = "\(room.id.uuidString).usdz"
            do {
                try captured.export(to: modelsDirectory.appendingPathComponent(fileName), exportOptions: .parametric)
                room.modelFileName = fileName
            } catch {
                print("LiDAR scan: could not save 3D model: \(error)")
            }
            onFinish(room)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: LiDARScanViewController, context: Context) {}
}

final class LiDARScanViewController: UIViewController, RoomCaptureViewDelegate {
    var onCancel: (() -> Void)?
    var onFinish: ((CapturedRoom) -> Void)?

    private var captureView: RoomCaptureView!
    private var finalRoom: CapturedRoom?
    private var isScanning = false
    private let cancelButton = UIButton(configuration: .gray())
    private let doneButton = UIButton(configuration: .filled())

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        captureView = RoomCaptureView(frame: view.bounds)
        captureView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        captureView.delegate = self
        view.addSubview(captureView)

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        doneButton.setTitle("Done", for: .normal)
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)

        for button in [cancelButton, doneButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(button)
        }
        NSLayoutConstraint.activate([
            cancelButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            doneButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            doneButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !isScanning, finalRoom == nil else { return }
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        isScanning = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isScanning { captureView.captureSession.stop() }
        isScanning = false
    }

    @objc private func cancelTapped() {
        if isScanning { captureView.captureSession.stop() }
        isScanning = false
        onCancel?()
    }

    @objc private func doneTapped() {
        if isScanning {
            // Stop scanning; RoomPlan then builds the final model and shows it.
            captureView.captureSession.stop()
            isScanning = false
            doneButton.setTitle("Processing…", for: .normal)
            doneButton.isEnabled = false
        } else if let finalRoom {
            onFinish?(finalRoom)
        }
    }

    // MARK: RoomCaptureViewDelegate

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        if let error {
            doneButton.setTitle("Scan failed", for: .normal)
            print("LiDAR scan failed: \(error)")
            return
        }
        finalRoom = processedResult
        doneButton.setTitle("Save Room", for: .normal)
        doneButton.isEnabled = true
    }
}
