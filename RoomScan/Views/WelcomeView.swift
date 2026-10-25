import SwiftUI

/// Short tutorial shown on first launch, and again from Settings.
struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private struct Page {
        let symbol: String
        let title: String
        let text: String
        let steps: [String]
    }

    private let pages = [
        Page(symbol: "house.and.flag",
             title: "Walk through a property",
             text: "RoomScan maps every room and documents what is in it, so you leave with a floor plan, an item list and a report.",
             steps: ["Tap Start a Walkthrough and name the property.",
                     "Map one room, then tap Next Room as you walk to the next.",
                     "Tap Done when the whole house is mapped."]),
        Page(symbol: "ruler",
             title: "Map each room",
             text: "Stand in the room and point the phone at the floor until a ring appears.",
             steps: ["Aim the + at a corner where two walls meet the floor.",
                     "Tap Add Corner. Go around the room in order.",
                     "The walls and floor area are measured for you."]),
        Page(symbol: "sparkles",
             title: "Let AI find the items",
             text: "AI Find Items looks at what the camera sees and adds each item with its condition and a photo.",
             steps: ["Point at one wall and tap AI Find Items.",
                     "Repeat for each wall, then tilt up for ceiling lights and vents.",
                     "Use AI looks for to pick only certain things, like windows and doors."]),
        Page(symbol: "cart.badge.plus",
             title: "Add what the customer asks for",
             text: "After mapping, open a room to fix anything the AI missed and record customer requests.",
             steps: ["Tap the room's plan where an item is to add it there.",
                     "Open an item, like a desk, and tap Add Item on Top for a phone on it.",
                     "Turn on Customer requested for anything they want added."]),
        Page(symbol: "square.and.arrow.up",
             title: "Export your findings",
             text: "On the property page, tap Export Findings.",
             steps: ["Pick the rooms and items to include.",
                     "Share a PDF report with photos, a spreadsheet, or quote data for QuoteMaster."]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    pageView(pages[index])
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            HStack {
                Button("Skip") { dismiss() }
                    .opacity(page == pages.count - 1 ? 0 : 1)
                Spacer()
                Button {
                    if page == pages.count - 1 {
                        dismiss()
                    } else {
                        withAnimation { page += 1 }
                    }
                } label: {
                    Text(page == pages.count - 1 ? "Get Started" : "Next")
                        .font(.headline)
                        .frame(minWidth: 120, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    private func pageView(_ page: Page) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: page.symbol)
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                    .padding(.top, 48)
                Text(page.title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text(page.text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(page.steps.indices, id: \.self) { index in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(.tint))
                            Text(page.steps[index])
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
    }
}

/// How to map a room, opened with the ? button while scanning.
struct ScanHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("1. Find the floor") {
                    tip("iphone.gen3.radiowaves.left.and.right", "Point the phone at the floor and move it slowly side to side until a ring appears under the +.")
                    tip("lightbulb", "Good light helps. Plain, shiny or very dark floors take longer.")
                }
                Section("2. Mark the corners") {
                    tip("plus.viewfinder", "Aim the + at the spot where two walls meet the floor and tap Add Corner.")
                    tip("arrow.triangle.turn.up.right.diamond", "Go around the room in order. A sofa in a corner? Aim where the corner would be.")
                    tip("arrow.uturn.backward", "Wrong spot? Tap the undo arrow to remove the last corner.")
                }
                Section("3. Find the items") {
                    tip("sparkles", "Point at one wall and tap AI Find Items. Do the same for each wall.")
                    tip("light.recessed", "Tilt up and scan the ceiling for lights, vents and smoke detectors.")
                    tip("line.3.horizontal.decrease.circle", "Tap AI looks for to pick only certain things, like electrical or windows and doors.")
                    tip("mappin.and.ellipse", "To add an item yourself, aim the + at it on the floor and tap the pin button.")
                }
                Section("4. Next room") {
                    tip("arrow.right.square", "Tap Next Room, name it, and walk slowly through the doorway with the camera on.")
                    tip("checkmark.circle", "Tap Done after the last room. You can fix anything later on the room page.")
                }
            }
            .navigationTitle("How to Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
    }
}
