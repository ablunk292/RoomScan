# RoomScan

iPhone app for scanning rooms, documenting what is inside, and turning walkthroughs into quotes.

## What works in this first version

- **Corner measure (any recent iPhone, including iPhone 14):** point the crosshair at each floor corner and tap **Add Corner**. The app measures each wall as you go and works out floor area and perimeter. Tap the pin button to drop an item (outlet, thermostat, TV…) where the crosshair is.
- **LiDAR scan (iPhone 12 Pro or newer Pro, iPad Pro):** uses Apple's RoomPlan to scan the whole room. Walls, doors, windows, ceiling height and furniture or appliances are found automatically, and a 3D model is saved.
- **Room page:** floor plan with wall lengths and numbered item pins, measurements, existing items with their condition, customer-requested items, notes, and a text summary you can share.
- Feet or meters, switchable on the home screen. Rooms are saved on the phone.

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
- Go around the room in order, then tap **Finish**. You need at least 3 corners.
- Without LiDAR, expect measurements within a few inches on a typical room. Measure ceiling height with a tape and type it in on the room page.

## Project layout

- `RoomScan/Capture/` – corner measuring (ARKit) and LiDAR scanning (RoomPlan)
- `RoomScan/Models/` – room data, geometry, units, and saving to the phone
- `RoomScan/Views/` – home screen, room page, floor plan drawing, item editor

The app needs iOS 17 or newer.
