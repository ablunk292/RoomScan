import ARKit
import SwiftUI

/// Readout and buttons for the measure tool, shared by the mapping screen and the
/// stand-alone measure screen.
struct MeasurePanel: View {
    @ObservedObject var tool: MeasureTool
    let useFeet: Bool
    let savedCount: Int
    let onSave: (SavedMeasurement) -> Void
    let onClose: () -> Void

    @State private var naming = false
    @State private var name = ""
    @State private var length: Double = 0

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text(tool.liveLength.map { Units.length($0, feet: useFeet) } ?? "—")
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                Text(tool.hasStart
                     ? "Aim the + at the second point and tap Set Point."
                     : "Aim the + at where the measurement starts and tap Set Point.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                if savedCount > 0 {
                    Text("\(savedCount) measurement\(savedCount == 1 ? "" : "s") saved in this room")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

            HStack(spacing: 12) {
                Button {
                    tool.clear()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!tool.hasStart)

                Button {
                    tool.setPoint()
                } label: {
                    Label("Set Point", systemImage: "smallcircle.filled.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!tool.isAimed)

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
            }
        }
        .onChange(of: tool.finishedLength) {
            if let finished = tool.finishedLength {
                length = finished
                name = ""
                naming = true
            }
        }
        .alert("Save this measurement?", isPresented: $naming) {
            TextField("New wall, window width…", text: $name)
            Button("Save") {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                onSave(SavedMeasurement(name: trimmed.isEmpty ? "Measurement" : trimmed, length: length))
                tool.finishedLength = nil
            }
            Button("Don't Save", role: .cancel) {
                tool.finishedLength = nil
                tool.clear()
            }
        } message: {
            Text("\(Units.length(length, feet: useFeet)). Give it a name so you know what it is later.")
        }
    }
}

/// A tape measure on its own, opened from a room's page.
struct MeasureScreen: View {
    let roomName: String
    let onSave: (SavedMeasurement) -> Void
    let onClose: () -> Void

    @StateObject private var model = StandaloneMeasure()
    @AppStorage(Units.useFeetKey) private var useFeet = true
    @State private var savedCount = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ARViewContainer(view: model.sceneView)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
            Image(systemName: "plus")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white)
                .shadow(radius: 2)
                .allowsHitTesting(false)
            VStack {
                HStack {
                    Text("Measure in \(roomName)")
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    Button("Done", action: onClose)
                        .buttonStyle(.borderedProminent)
                }
                Text("Move the phone slowly so it can see the floor and walls first.")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer()
                MeasurePanel(tool: model.tool, useFeet: useFeet, savedCount: savedCount, onSave: { measurement in
                    savedCount += 1
                    onSave(measurement)
                }, onClose: onClose)
            }
            .padding()
        }
        .onAppear { model.start() }
        .onDisappear { model.pause() }
    }
}

/// The AR session behind the stand-alone measure screen.
final class StandaloneMeasure: NSObject, ObservableObject, ARSCNViewDelegate {
    let sceneView = ARSCNView()
    lazy var tool: MeasureTool = {
        let tool = MeasureTool(sceneView: sceneView)
        tool.isShowing = true
        return tool
    }()
    private var updatePending = false

    override init() {
        super.init()
        sceneView.delegate = self
        sceneView.automaticallyUpdatesLighting = true
        _ = tool
    }

    func start() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        sceneView.session.run(configuration)
    }

    func pause() {
        sceneView.session.pause()
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard !updatePending else { return }
        updatePending = true
        DispatchQueue.main.async { [weak self] in
            self?.tool.update()
            self?.updatePending = false
        }
    }
}
