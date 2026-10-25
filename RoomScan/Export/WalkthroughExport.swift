import Foundation

/// The data file handed to other tools. Besides every room and item, it carries a draft quote
/// shaped like QuoteMaster's Quote record (one header per room, a line for each item the
/// customer requested or that needs repair or replacement), so QuoteMaster can open it as a
/// quote ready for pricing.
struct WalkthroughExport: Encodable {
    struct Customer: Encodable {
        var name: String
        var email: String
        var phone: String
    }

    struct QuoteLine: Encodable {
        var itemType: String
        var productName: String
        var description: String
        var quantity: Double?
        var unitPrice: Double?

        enum CodingKeys: String, CodingKey {
            case itemType = "item_type"
            case productName = "product_name"
            case description, quantity
            case unitPrice = "unit_price"
        }
    }

    struct QuoteDraft: Encodable {
        var title: String
        var clientName: String
        var clientEmail: String
        var clientPhone: String
        var clientAddress: String
        var notes: String
        var items: [QuoteLine]

        enum CodingKeys: String, CodingKey {
            case title, notes, items
            case clientName = "client_name"
            case clientEmail = "client_email"
            case clientPhone = "client_phone"
            case clientAddress = "client_address"
        }
    }

    var format = "roomscan.walkthrough.v1"
    var exportedAt = Date()
    var property: Property
    var customer: Customer
    var quoteDraft: QuoteDraft

    enum CodingKeys: String, CodingKey {
        case format, property, customer
        case exportedAt = "exported_at"
        case quoteDraft = "quote_draft"
    }

    init(property: Property, useFeet: Bool) {
        self.property = property
        customer = Customer(
            name: property.customerName ?? "",
            email: property.customerEmail ?? "",
            phone: property.customerPhone ?? ""
        )

        var lines: [QuoteLine] = []
        for room in property.rooms {
            let quotable = room.items.filter { $0.isRequested || $0.condition == .needsRepair || $0.condition == .needsReplacement }
            guard !quotable.isEmpty else { continue }
            lines.append(QuoteLine(itemType: "header", productName: room.name,
                                   description: "\(Units.area(room.area, feet: useFeet)) floor area"))
            for item in quotable {
                let action = item.isRequested ? "Customer request" : item.condition.label
                let placement = room.item(item.parentID).map { "On \($0.name)" } ?? ""
                let description = [action, item.category, placement, item.notes].filter { !$0.isEmpty }.joined(separator: " · ")
                lines.append(QuoteLine(itemType: "product", productName: item.name, description: description,
                                       quantity: Double(item.quantity), unitPrice: 0))
            }
        }

        quoteDraft = QuoteDraft(
            title: "Walkthrough – \(property.name)",
            clientName: property.customerName ?? property.name,
            clientEmail: property.customerEmail ?? "",
            clientPhone: property.customerPhone ?? "",
            clientAddress: property.address,
            notes: property.notes,
            items: lines
        )
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// One row per item, for Excel, Numbers or Google Sheets.
    static func csv(for property: Property, useFeet: Bool) -> String {
        let header = ["Room", "Room area", "Item", "Category", "Quantity", "Condition",
                      "Customer requested", "Found by AI", "On top of", "Notes"]
        var rows = [header]
        for room in property.rooms {
            let area = Units.area(room.area, feet: useFeet)
            if room.items.isEmpty {
                rows.append([room.name, area, "", "", "", "", "", "", "", room.notes])
            }
            for item in room.items {
                rows.append([
                    room.name, area, item.name, item.category, "\(item.quantity)",
                    item.isRequested ? "" : item.condition.label,
                    item.isRequested ? "Yes" : "No",
                    item.detectedAutomatically ? "Yes" : "No",
                    room.item(item.parentID)?.name ?? "",
                    item.notes,
                ])
            }
        }
        return rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n")
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
