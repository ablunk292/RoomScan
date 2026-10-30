import SwiftUI
import UIKit

/// The iOS share sheet, for files made on demand (AirDrop, Mail, Files, Messages…).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Files waiting to be shared; identifiable so a sheet can present them.
struct SharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}
