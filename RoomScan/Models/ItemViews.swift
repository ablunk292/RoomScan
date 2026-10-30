import Foundation
import SwiftUI

/// Which items a list shows.
struct ItemFilter: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case all = "All"
        case existing = "Existing"
        case requested = "Requested"

        var id: Self { self }
    }

    var categories: Set<String> = []
    var kind: Kind = .all
    var conditions: Set<ItemCondition> = []
    var aiOnly = false

    var isEmpty: Bool { categories.isEmpty && kind == .all && conditions.isEmpty && !aiOnly }

    func matches(_ item: RoomItem) -> Bool {
        if !categories.isEmpty, !categories.contains(item.category) { return false }
        if kind == .existing, item.isRequested { return false }
        if kind == .requested, !item.isRequested { return false }
        if !conditions.isEmpty, item.isRequested || !conditions.contains(item.condition) { return false }
        if aiOnly, !item.detectedAutomatically { return false }
        return true
    }
}

/// A saved filter with a name, like "IT & Electrical".
struct ItemView: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var filter: ItemFilter
}

/// The saved item views, the one new walkthroughs start with, and the one picked for each
/// walkthrough. Kept on this phone.
@MainActor
final class ItemViews: ObservableObject {
    static let shared = ItemViews()

    private struct Saved: Codable {
        var views: [ItemView]
        var defaultID: UUID?
        /// Walkthrough id → view id, or "" for everything.
        var chosen: [String: String]
    }

    @Published private var saved: Saved
    private let key = "itemViews"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = decoded
        } else {
            saved = Saved(views: [
                ItemView(name: "IT & Electrical", filter: ItemFilter(categories: ["Electrical", "Network / AV", "Security"])),
                ItemView(name: "Requests", filter: ItemFilter(kind: .requested)),
            ], defaultID: nil, chosen: [:])
        }
    }

    var views: [ItemView] { saved.views }
    var defaultID: UUID? { saved.defaultID }

    /// The view a walkthrough shows, or nil for everything.
    func view(for propertyID: UUID) -> ItemView? {
        let id = saved.chosen[propertyID.uuidString].map { UUID(uuidString: $0) } ?? saved.defaultID
        return id.flatMap { id in saved.views.first { $0.id == id } }
    }

    func choose(_ view: ItemView?, for propertyID: UUID) {
        saved.chosen[propertyID.uuidString] = view?.id.uuidString ?? ""
        save()
    }

    @discardableResult
    func add(name: String, filter: ItemFilter) -> ItemView {
        let view = ItemView(name: name, filter: filter)
        saved.views.append(view)
        save()
        return view
    }

    func update(_ view: ItemView) {
        guard let index = saved.views.firstIndex(where: { $0.id == view.id }) else { return }
        saved.views[index] = view
        save()
    }

    func delete(_ view: ItemView) {
        saved.views.removeAll { $0.id == view.id }
        if saved.defaultID == view.id { saved.defaultID = nil }
        saved.chosen = saved.chosen.filter { $0.value != view.id.uuidString }
        save()
    }

    func setDefault(_ view: ItemView?) {
        saved.defaultID = view?.id
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// A row of saved views to switch between. Long-press a view to rename it, make it the
/// default for new walkthroughs, or delete it.
struct ItemViewBar: View {
    let propertyID: UUID
    /// The filters on screen right now, when they can be saved as a new view.
    var unsavedFilter: ItemFilter?
    var onChoose: (ItemView?) -> Void = { _ in }

    @ObservedObject private var views = ItemViews.shared
    @State private var naming: ItemView?
    @State private var name = ""

    var body: some View {
        let current = views.view(for: propertyID)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Everything", icon: "square.grid.2x2", on: current == nil) {
                    views.choose(nil, for: propertyID)
                    onChoose(nil)
                }
                ForEach(views.views) { view in
                    chip(view.name, icon: views.defaultID == view.id ? "star.fill" : nil, on: current?.id == view.id) {
                        views.choose(view, for: propertyID)
                        onChoose(view)
                    }
                    .contextMenu {
                        Button {
                            name = view.name
                            naming = view
                        } label: { Label("Rename", systemImage: "pencil") }
                        if views.defaultID == view.id {
                            Button {
                                views.setDefault(nil)
                            } label: { Label("Stop Using for New Walkthroughs", systemImage: "star.slash") }
                        } else {
                            Button {
                                views.setDefault(view)
                            } label: { Label("Use for New Walkthroughs", systemImage: "star") }
                        }
                        Button(role: .destructive) {
                            if current?.id == view.id { onChoose(nil) }
                            views.delete(view)
                        } label: { Label("Delete View", systemImage: "trash") }
                    }
                }
                if let unsavedFilter, !unsavedFilter.isEmpty, unsavedFilter != current?.filter {
                    if let current {
                        Button("Update \"\(current.name)\"") {
                            var updated = current
                            updated.filter = unsavedFilter
                            views.update(updated)
                        }
                        .font(.footnote)
                    }
                    Button {
                        name = ""
                        naming = ItemView(name: "", filter: unsavedFilter)
                    } label: {
                        Label("Save View", systemImage: "plus")
                    }
                    .font(.footnote)
                }
            }
            .buttonStyle(.borderless)
        }
        .alert(naming.map { v -> String in views.views.contains { $0.id == v.id } ? "Rename view" : "Save view" } ?? "",
               isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name, like IT & Electrical", text: $name)
            Button("Save") {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                guard var view = naming, !trimmed.isEmpty else { return }
                view.name = trimmed
                if views.views.contains(where: { $0.id == view.id }) {
                    views.update(view)
                } else {
                    let added = views.add(name: trimmed, filter: view.filter)
                    views.choose(added, for: propertyID)
                    onChoose(added)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved views show on every walkthrough. Each walkthrough remembers the one you picked.")
        }
    }

    private func chip(_ title: String, icon: String?, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.caption2) }
                Text(title)
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: Capsule())
            .foregroundStyle(on ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

/// Asks for a quick note on an item, without opening the full editor.
struct QuickNote: Identifiable {
    let roomID: UUID
    let item: RoomItem
    var id: UUID { item.id }
}
