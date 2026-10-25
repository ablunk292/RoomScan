import ARKit
import SwiftUI

struct CornerMeasureScreen: View {
    let roomName: String
    let onCancel: () -> Void
    let onFinish: (Room) -> Void

    @StateObject private var controller = CornerMeasureController()
    @AppStorage(Units.useFeetKey) private var useFeet = true
    @State private var askingItemName = false
    @State private var itemName = ""

    var body: some View {
        ZStack {
            ARViewContainer(view: controller.sceneView)
                .ignoresSafeArea()

            Image(systemName: "plus")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white)
                .shadow(radius: 2)
                .allowsHitTesting(false)

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
            Text("The item is pinned where the crosshair meets the floor. You can add details after saving.")
        }
    }

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Spacer()
                Text(roomName).font(.headline)
                Spacer()
                Button("Finish") { onFinish(controller.makeRoom(named: roomName)) }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.corners.count < 3)
            }
            Text(controller.status)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                stat("Corners", "\(controller.corners.count)")
                if let distance = controller.liveDistance {
                    stat("This wall", Units.length(distance, feet: useFeet))
                }
                if controller.corners.count >= 3 {
                    let area = Geometry.area(of: controller.corners.map { Point2D(x: Double($0.x), y: Double($0.z)) })
                    stat("Area", Units.area(area, feet: useFeet))
                }
                stat("Items", "\(controller.items.count)")
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

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
                    Label("Add Corner", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.aimPoint == nil)

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
