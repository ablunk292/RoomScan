import Foundation

/// Formats meters for display in feet and inches or in meters.
enum Units {
    static let useFeetKey = "useFeet"

    static var useFeet: Bool {
        UserDefaults.standard.object(forKey: useFeetKey) as? Bool ?? true
    }

    static func length(_ meters: Double, feet: Bool = Units.useFeet) -> String {
        if feet {
            let totalInches = (meters / 0.0254).rounded()
            let ft = Int(totalInches / 12)
            let inches = Int(totalInches) - ft * 12
            return inches == 0 ? "\(ft)′" : "\(ft)′ \(inches)″"
        }
        return String(format: "%.2f m", meters)
    }

    static func area(_ squareMeters: Double, feet: Bool = Units.useFeet) -> String {
        if feet {
            return String(format: "%.0f sq ft", squareMeters * 10.7639)
        }
        return String(format: "%.1f m²", squareMeters)
    }

    /// Converts a number typed in the current unit (feet or meters) to meters.
    static func meters(fromDisplay value: Double, feet: Bool = Units.useFeet) -> Double {
        feet ? value * 0.3048 : value
    }

    static func display(fromMeters value: Double, feet: Bool = Units.useFeet) -> Double {
        feet ? value / 0.3048 : value
    }
}
