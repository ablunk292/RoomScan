import SwiftUI

/// Drag and turn rooms on the house plan by hand. A room snaps to its neighbors' walls
/// when it is let go close to them.
struct ArrangeRoomsView: View {
    let propertyID: Property.ID

    @EnvironmentObject private var store: PropertyStore
    @Environment(\.dismiss) private var dismiss
    @State private var rooms: [Room] = []
    @State private var selected: Int?
    /// Area the drawing is fitted to, fixed while editing so the plan does not rescale under a finger.
    @State private var viewport: [Point2D] = []
    @State private var dragStart: Point2D?
    @State private var dragOriginal: Room?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    let frame = PlanFrame(points: viewport, size: geometry.size, inset: 16)
                    Canvas { context, _ in
                        guard let frame else { return }
                        draw(in: &context, frame: frame)
                    }
                    .contentShape(Rectangle())
                    .gesture(dragGesture(frame: frame))
                }
                .background(Color(.secondarySystemBackground))

                controls
            }
            .navigationTitle("Arrange Rooms")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if var property = store.property(id: propertyID) {
                            property.rooms = rooms
                            store.update(property)
                        }
                        dismiss()
                    }
                }
            }
            .onAppear(perform: load)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Text(selected.map { "\(rooms[$0].name): drag to move, or turn it below." }
                 ?? "Touch a room to pick it up and drag it into place.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button { turnSelected(by: -.pi / 2) } label: {
                    Label("Turn left", systemImage: "rotate.left")
                }
                Button { turnSelected(by: .pi / 2) } label: {
                    Label("Turn right", systemImage: "rotate.right")
                }
                Button { tidyAll() } label: {
                    Label("Auto-align", systemImage: "square.grid.3x3")
                }
            }
            .buttonStyle(.bordered)
            .labelStyle(.titleAndIcon)
            .font(.callout)
        }
        .padding()
    }

    private func load() {
        guard rooms.isEmpty, let property = store.property(id: propertyID) else { return }
        rooms = property.rooms
        resetViewport()
    }

    /// Leaves a margin around the plan so rooms can be dragged outward.
    private func resetViewport() {
        guard let bounds = Geometry.bounds(of: rooms.flatMap(\.outline)) else { return }
        let margin = max(bounds.maxX - bounds.minX, bounds.maxY - bounds.minY) * 0.25 + 1
        viewport = [
            Point2D(x: bounds.minX - margin, y: bounds.minY - margin),
            Point2D(x: bounds.maxX + margin, y: bounds.maxY + margin),
        ]
    }

    private func draw(in context: inout GraphicsContext, frame: PlanFrame) {
        for (index, room) in rooms.enumerated() where room.outline.count >= 3 {
            var path = Path()
            path.addLines(room.outline.map(frame.map))
            path.closeSubpath()
            let isSelected = index == selected
            context.fill(path, with: .color(isSelected ? Color.accentColor.opacity(0.35) : Color.accentColor.opacity(0.12)))
            context.stroke(path, with: .color(isSelected ? .accentColor : .primary), lineWidth: isSelected ? 3 : 2)
            if let center = Geometry.center(of: room.outline) {
                context.draw(Text(room.name).font(.caption.weight(.semibold)), at: frame.map(center))
            }
        }
    }

    private func dragGesture(frame: PlanFrame?) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let frame else { return }
                let point = frame.unmap(value.location)
                if dragStart == nil {
                    let start = frame.unmap(value.startLocation)
                    selected = rooms.lastIndex { Geometry.contains($0.outline, start) }
                    dragStart = start
                    dragOriginal = selected.map { rooms[$0] }
                }
                guard let index = selected, let start = dragStart, let original = dragOriginal else { return }
                rooms[index] = original.translated(dx: point.x - start.x, dy: point.y - start.y)
            }
            .onEnded { _ in
                if let index = selected, dragOriginal != nil {
                    snap(index)
                }
                dragStart = nil
                dragOriginal = nil
            }
    }

    private func snap(_ index: Int) {
        let others = rooms.enumerated().filter { $0.offset != index }.map(\.element)
        rooms[index] = Layout.snapped(rooms[index], to: others, angle: Layout.dominantAngle(of: rooms))
    }

    private func turnSelected(by angle: Double) {
        guard let index = selected else { return }
        rooms[index] = rooms[index].rotated(by: angle)
        snap(index)
    }

    private func tidyAll() {
        rooms = Layout.tidy(rooms)
        resetViewport()
    }
}
