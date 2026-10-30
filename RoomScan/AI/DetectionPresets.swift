import Foundation

/// A saved instruction for AI Find Items, such as "Windows, doors and door handles".
struct DetectionPreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// What the AI should look for, in plain words. Empty means everything.
    var focus: String
}

/// The presets the user keeps, and what AI Find Items is looking for right now.
/// Saved on the phone, so they are the same in every room and property. Used from the main thread.
final class DetectionPresets: ObservableObject {
    static let shared = DetectionPresets()

    @Published var presets: [DetectionPreset] {
        didSet { save() }
    }
    /// What the next AI scan looks for. Empty means everything.
    @Published var activeFocus: String {
        didSet { UserDefaults.standard.set(activeFocus, forKey: Self.activeKey) }
    }

    private static let presetsKey = "detectionPresets"
    private static let activeKey = "detectionActiveFocus"

    static let starters = [
        DetectionPreset(name: "Furniture, IT and electrical",
                        focus: "Main furniture; IT and network equipment (computers, monitors, printers, phones, routers, switches, network jacks); electrical (outlets, switches, panels, light fixtures)"),
        DetectionPreset(name: "Windows and doors",
                        focus: "Windows, doors and their hardware: door handles, knobs, locks, hinges, closers, window latches, blinds and screens"),
        DetectionPreset(name: "Electrical only",
                        focus: "Electrical items only: outlets, switches, cover plates, panels, light fixtures, ceiling fans, smoke and CO detectors"),
        DetectionPreset(name: "Plumbing",
                        focus: "Plumbing fixtures: sinks, faucets, toilets, tubs, showers, water heaters, visible pipes and shut-off valves"),
        DetectionPreset(name: "Damage and wear",
                        focus: "Only visible damage or wear: water stains, cracks, holes, peeling paint, missing covers, broken fixtures"),
    ]

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.presetsKey),
           let saved = try? JSONDecoder().decode([DetectionPreset].self, from: data) {
            presets = saved
        } else {
            presets = Self.starters
        }
        activeFocus = defaults.string(forKey: Self.activeKey) ?? ""
    }

    /// Short name for what the AI is looking for, for buttons and labels.
    var activeName: String {
        let focus = activeFocus.trimmingCharacters(in: .whitespacesAndNewlines)
        if focus.isEmpty { return "Everything" }
        return presets.first { $0.focus == activeFocus }?.name ?? focus
    }

    private func save() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Self.presetsKey)
        }
    }
}
