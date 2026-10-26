# RoomScan

iPhone app for scanning rooms, documenting what is inside, and turning walkthroughs into quotes.

## What it does

- **Guided from the start:** a short tutorial on first launch (Settings → Show Tutorial to see it again). While mapping, a card at the top says which step you are on (find the floor, mark the corners, find the items, finish the room) and what to do next, and the button to tap next is highlighted. The ? button opens a How to Scan guide.
- **Whole properties:** create a house, apartment or building, then map its rooms one after another in a single walk. Tap **Next Room** as you go; rooms mapped in one session line up into a whole-house floor plan.
- **Corner mapping (any recent iPhone, including iPhone 14):** point the crosshair at each floor corner and tap **Add Corner**. The app measures each wall as you go and works out floor area and perimeter. Tap the pin button to place an item yourself.
- **Guided AI item scan:** once a room's corners are marked, tap **Room Mapped – Scan Items**. First aim the + where a wall meets the ceiling and tap **Set Ceiling Height**. Then a grid covers each wall, the ceiling and the floor. The part to scan pulses orange and an arrow points to it when it's off screen. Put the + on an orange square and hold still: the photo is taken automatically and sent to the AI. Squares turn blue while the AI looks and green when done. A **Slow down** warning appears if the phone moves too fast. Items outside the room are left out, and doors and windows are drawn on the walls in the floor plan. **Skip** and **Snap Now** are there for parts you can't reach. Needs you to be signed in (see below).
- **Closing the room:** after the last corner, aim back at the first one (it pulses green and the + snaps to it) and tap **Close Room**. The AI scan only starts once the outline is closed.
- **Measure tool:** tap the ruler while mapping (or **Take a Measurement** on a room's page), tap **Set Point** at each end, and name the measurement to save it to the room. Saved measurements appear on the room page, in the PDF, the spreadsheet and the text summary.
- **Full camera view:** the mapping screen shows the whole camera picture instead of a zoomed-in crop, so you see exactly what the AI sees.
- **Tell the AI what to look for:** tap **AI looks for** above the buttons to pick a preset (such as *Windows and doors* or *Furniture, IT and electrical*) or type your own, like "door handles and locks". The AI then picks up only those things. You can also pick it before you start, on the New Property and Add Rooms screens. Save your own presets there or under Settings → **AI Presets**.
- **AI reminder per room:** if you tap **Next Room** or **Done** before AI Find Items has looked at the room, the app asks whether to scan it first. The AI only sees what is in the camera view, so tilt up to scan the ceiling for lights, vents and detectors.
- **Item photos:** each item the AI finds keeps a close-up cut from the photo it looked at, so you can see how and where it sits in the room. Take or choose a photo for any item in its editor. Photos show in the item list and the PDF report.
- **Items on other items:** open an item (for example a desk) and tap **Add Item on Top** or **Add Requested Item on Top** to add something that sits on it, like a phone. It is listed under the desk and pinned next to it on the plan. You can also set **Sits on** in any item. Tapping the plan to add an item still works as before.
- **LiDAR scan (iPhone 12 Pro or newer Pro, iPad Pro):** uses Apple's RoomPlan to scan each room. Walls, doors, windows, ceiling height and furniture or appliances are found automatically, and a 3D model is saved. AI Find Items works here too.
- **Clean floor plans:** walls that are nearly square are straightened, and neighboring rooms snap together at shared walls (a 4.5 inch interior wall is assumed). Angled walls more than 15° off are kept as measured.
- **Arrange Rooms:** on the property page, drag rooms into place and turn them 90°; a room snaps to nearby walls when you let go. **Auto-align** straightens and snaps everything at once.
- **Property page:** whole-house floor plan, total area, room list, and a shareable summary of every room.
- **Room page:** floor plan with wall lengths and numbered item pins, measurements, existing items with their condition, customer-requested items, notes, and rename.
- **Export Findings** (property page): pick the rooms, which findings (all existing items, only ones needing work, or none; customer requests; photos) and which files to make. Files: a PDF report with the house plan and a page per room, a CSV spreadsheet of every item, and a JSON data file. The JSON includes a `quote_draft` shaped like a QuoteMaster quote (a header per room, a line for each requested item or item needing repair or replacement) for the upcoming QuoteMaster integration.
- **LiDAR check:** phones without LiDAR get a one-time notice, the LiDAR option is marked unavailable, and Settings shows whether this iPhone supports it.
- **Sign in with QuoteMaster** (Settings → Account): RoomScan uses the same accounts as QuoteMaster. Signed in, the AI runs on the RoomScan server (no key on the phone), walkthroughs and photos sync to your company's account, and you can open them on a computer. Pull down on the home screen to sync now.
- **Send to QuoteMaster** (property page): syncs the walkthrough and opens the web app's quote wizard. Its six steps are items, client, opportunity, look, products and prices (the AI matches items to your QuoteMaster products), and review. It creates a draft quote in QuoteMaster for you to check. Nothing is sent to the customer.
- **Web editor** at https://roomscan-web-theta.vercel.app: sign in with the same account to drag rooms, corners and items on the floor plan, type exact wall lengths, add rooms, items and customer requests, filter and bulk-edit items, print a PDF report or download a spreadsheet, ask the AI helper about the walkthrough, and send it to QuoteMaster. Changes sync back to the phone.
- Feet or meters in Settings. Everything is also saved on the phone, so it works without a signal.

## Cloud and AI

RoomScan shares QuoteMaster's Supabase project:

- `roomscan_property` holds each walkthrough as JSON with a `version` that goes up on every save. If a walkthrough changed on the phone and somewhere else since the last sync, the cloud copy wins and the phone's edits are kept as a separate walkthrough named "(phone copy)".
- `roomscan-photos` is a private storage bucket for item photos, kept in a folder per company.
- `roomscan-ai` is a server function that holds the Claude key. It handles photo scans, matching items to QuoteMaster products, and the web AI helper.
- `roomscan_quote_link` records which quotes were made from which walkthrough.

The database changes and the function's source are in the quotemaster repo (`supabase/migrations/20261026004153_roomscan.sql` and `supabase/functions/roomscan-ai`).

In test (Debug) builds, Settings still has a developer field for a Claude API key, used only when you are not signed in. Release builds don't show it.

## Web app

The web editor is in `web/` (Vite, React and TypeScript) and is hosted on Vercel as the `roomscan-web` project. To run it locally:

```
cd web
npm install
cp .env.example .env.local
npm run dev
```

## Run it on your iPhone

You need a Mac with Xcode (free from the Mac App Store), your iPhone, and a USB cable. A paid Apple Developer account is not needed for testing; without one, the app stops opening after 7 days and you reinstall it from Xcode.

1. On the Mac, open **Terminal** and run:
   ```
   git clone https://github.com/ablunk292/RoomScan.git
   open RoomScan/RoomScan.xcodeproj
   ```
2. In Xcode, open **Xcode → Settings → Accounts**, click **+**, and sign in with your Apple ID.
3. Click **RoomScan** at the top of the left sidebar, choose the **RoomScan** target, open **Signing & Capabilities**, and pick your name under **Team**. If Xcode says the bundle identifier is taken, change `com.ablunk292.roomscan` to something unique, like `com.yourname.roomscan`.
4. Plug in the iPhone and unlock it. Tap **Trust** if asked. On the iPhone, turn on **Settings → Privacy & Security → Developer Mode** and restart when asked.
5. In Xcode's top bar, choose your iPhone as the run destination and press **▶ Run** (or ⌘R).
6. The first time, the iPhone blocks the app. Go to **Settings → General → VPN & Device Management**, tap your Apple ID, and tap **Trust**. Then open RoomScan.

## Tips for accurate corner measuring

- Use good light, and start by slowly sweeping the phone across the floor until the crosshair appears.
- Aim at the exact spot where two walls meet the floor. Furniture in a corner: aim where the corner would be.
- Go around the room in order. You need at least 3 corners before **Next Room** or **Done**.
- Moving between rooms, keep the camera running and walk slowly through the doorway so tracking stays locked.
- Without LiDAR, expect measurements within a few inches on a typical room. Measure ceiling height with a tape and type it in on the room page.

## Project layout

- `RoomScan/Capture/` – corner mapping (ARKit) and LiDAR scanning (RoomPlan)
- `RoomScan/AI/` – AI item detection with Claude, camera photos, and the developer key
- `RoomScan/Cloud/` – sign-in, sync and calls to the RoomScan server
- `RoomScan/Models/` – properties, rooms, geometry, units, and saving to the phone
- `RoomScan/Views/` – home, property, room, settings, account, floor plan drawing, item editor
- `web/` – the web editor and QuoteMaster wizard

The app needs iOS 17 or newer.
