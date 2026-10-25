import SwiftUI
import UIKit

/// A printable walkthrough report: summary and house plan first, then a page section per
/// room with its plan, measurements and item list.
@MainActor
enum PDFReport {
    private static let page = CGRect(x: 0, y: 0, width: 612, height: 792)   // US Letter
    private static let margin: CGFloat = 40
    private static var contentWidth: CGFloat { page.width - margin * 2 }

    static func data(for property: Property, useFeet: Bool) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        return renderer.pdfData { context in
            var writer = Writer(context: context)
            writer.newPage()

            writer.text(property.name, font: .boldSystemFont(ofSize: 22))
            var subtitle = [property.address, property.createdAt.formatted(date: .long, time: .omitted)]
            if let customer = property.customerName, !customer.isEmpty { subtitle.insert("Customer: \(customer)", at: 0) }
            writer.text(subtitle.filter { !$0.isEmpty }.joined(separator: "  ·  "), font: .systemFont(ofSize: 11), color: .darkGray)
            writer.space(10)
            writer.text("\(property.rooms.count) rooms  ·  \(Units.area(property.totalArea, feet: useFeet)) total  ·  \(property.itemCount) items  ·  \(property.requestedCount) customer requests",
                        font: .systemFont(ofSize: 12))
            writer.space(12)
            if let plan = planImage(rooms: property.rooms, showDetails: false, useFeet: useFeet, height: 360) {
                writer.image(plan)
            }
            if !property.notes.isEmpty {
                writer.space(8)
                writer.text("Notes: \(property.notes)", font: .systemFont(ofSize: 11))
            }

            for room in property.rooms {
                writer.newPage()
                writer.text(room.name, font: .boldSystemFont(ofSize: 18))
                var facts = ["Floor area \(Units.area(room.area, feet: useFeet))",
                             "Perimeter \(Units.length(room.perimeter, feet: useFeet))"]
                if let ceiling = room.ceilingHeight { facts.append("Ceiling \(Units.length(ceiling, feet: useFeet))") }
                facts.append(room.method.label)
                writer.text(facts.joined(separator: "  ·  "), font: .systemFont(ofSize: 11), color: .darkGray)
                let walls = room.wallLengths.enumerated().map { "Wall \($0.offset + 1): \(Units.length($0.element, feet: useFeet))" }
                writer.text(walls.joined(separator: "   "), font: .systemFont(ofSize: 10), color: .darkGray)
                writer.space(8)
                if let plan = planImage(rooms: [room], showDetails: true, useFeet: useFeet, height: 280) {
                    writer.image(plan)
                }
                writer.space(8)
                itemTable(title: "Existing items", room: room, items: room.items.filter { !$0.isRequested }, writer: &writer)
                itemTable(title: "Customer requested", room: room, items: room.items.filter(\.isRequested), writer: &writer)
                if !room.notes.isEmpty {
                    writer.space(6)
                    writer.text("Notes: \(room.notes)", font: .systemFont(ofSize: 11))
                }
            }
        }
    }

    private static func itemTable(title: String, room: Room, items: [RoomItem], writer: inout Writer) {
        guard !items.isEmpty else { return }
        writer.space(6)
        writer.text(title, font: .boldSystemFont(ofSize: 13))
        for item in items {
            let number = (room.items.firstIndex(of: item) ?? 0) + 1
            var line = "\(number).  \(item.name)"
            if item.quantity > 1 { line += " ×\(item.quantity)" }
            var details = [item.category]
            if !item.isRequested { details.append(item.condition.label) }
            if !item.notes.isEmpty { details.append(item.notes) }
            line += "  —  " + details.joined(separator: " · ")
            writer.text(line, font: .systemFont(ofSize: 11))
        }
    }

    /// Draws the same floor plan the app shows, in light colors for paper.
    private static func planImage(rooms: [Room], showDetails: Bool, useFeet: Bool, height: CGFloat) -> UIImage? {
        let view = FloorPlanView(rooms: rooms, showDetails: showDetails, useFeet: useFeet)
            .frame(width: contentWidth, height: height)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.uiImage
    }

    /// Lays out text and images top to bottom, starting a new page when one fills up.
    private struct Writer {
        let context: UIGraphicsPDFRendererContext
        var y: CGFloat = 0

        mutating func newPage() {
            context.beginPage()
            y = PDFReport.margin
        }

        mutating func space(_ height: CGFloat) {
            y += height
        }

        mutating func text(_ string: String, font: UIFont, color: UIColor = .black) {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = (string as NSString).boundingRect(
                with: CGSize(width: PDFReport.contentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil
            ).size
            if y + size.height > PDFReport.page.height - PDFReport.margin { newPage() }
            (string as NSString).draw(
                with: CGRect(x: PDFReport.margin, y: y, width: PDFReport.contentWidth, height: ceil(size.height)),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil
            )
            y += ceil(size.height) + 4
        }

        mutating func image(_ image: UIImage) {
            let height = image.size.height * (PDFReport.contentWidth / image.size.width)
            if y + height > PDFReport.page.height - PDFReport.margin { newPage() }
            image.draw(in: CGRect(x: PDFReport.margin, y: y, width: PDFReport.contentWidth, height: height))
            y += height + 4
        }
    }
}

/// Writes the export files to a temporary folder for sharing.
enum ExportFiles {
    @MainActor
    static func make(for property: Property, useFeet: Bool) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = property.name.replacingOccurrences(of: "/", with: "-")

        let pdf = folder.appendingPathComponent("\(base) Walkthrough.pdf")
        try PDFReport.data(for: property, useFeet: useFeet).write(to: pdf)

        let csv = folder.appendingPathComponent("\(base) Items.csv")
        try WalkthroughExport.csv(for: property, useFeet: useFeet).write(to: csv, atomically: true, encoding: .utf8)

        let json = folder.appendingPathComponent("\(base) Walkthrough.json")
        try WalkthroughExport(property: property, useFeet: useFeet).jsonData().write(to: json)

        return [pdf, csv, json]
    }
}
