import Foundation

/// An item Claude found in a photo. `x` and `y` are where its center is in the photo, and
/// `left`, `top`, `right` and `bottom` the edges of a box around it, all as fractions of the
/// width and height from the top-left corner.
struct DetectedItem: Decodable {
    var name: String
    var category: String
    var condition: ItemCondition
    var notes: String
    var x: Double
    var y: Double
    var left: Double
    var top: Double
    var right: Double
    var bottom: Double
    /// "door", "window" or "opening" when the item is a doorway or window in a wall,
    /// so it can be drawn on the floor plan; "none" otherwise.
    var opening: String?

    var openingKind: OpeningKind? {
        switch opening {
        case "door": return .door
        case "window": return .window
        case "opening": return .opening
        default: return nil
        }
    }
}

enum ItemDetectorError: LocalizedError {
    case missingKey
    case badResponse(String)
    case refused

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Sign in with your QuoteMaster account in Settings to use AI item detection."
        case .badResponse(let message): return message
        case .refused: return "The AI declined to analyze this photo."
        }
    }
}

/// Asks Claude to list everything worth documenting in a walkthrough photo.
/// Calls the Claude Messages API directly (there is no official Swift SDK).
/// Whether AI item detection can run: signed in to the RoomScan cloud, or a developer key is saved.
enum AIAccess {
    static var isAvailable: Bool { SessionStore.isSignedIn || APIKeyStore.hasKey }
}

enum ItemDetector {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-opus-5-5"

    /// `focus` limits the search to what the user asked for, such as "windows and door handles".
    /// Empty means everything worth documenting.
    static func detectItems(inJPEG jpeg: Data, roomName: String, focus: String = "") async throws -> [DetectedItem] {
        // Signed in: the RoomScan server calls Claude, so no key is needed on the phone.
        if SessionStore.isSignedIn {
            do {
                let data = try await CloudAPI.ai("detect", [
                    "image_base64": jpeg.base64EncodedString(),
                    "media_type": "image/jpeg",
                    "room_name": roomName,
                    "focus": focus,
                ])
                return try JSONDecoder().decode(ItemList.self, from: data).items
            } catch CloudError.notSignedIn {
                throw ItemDetectorError.missingKey
            } catch let error as CloudError {
                if case .http(422, _) = error { throw ItemDetectorError.refused }
                throw ItemDetectorError.badResponse(error.localizedDescription)
            }
        }
        // Developer testing without an account: a Claude key saved in Settings.
        guard let key = APIKeyStore.key else { throw ItemDetectorError.missingKey }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(jpeg: jpeg, roomName: roomName, focus: focus))

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ItemDetectorError.badResponse(errorMessage(from: data, status: status))
        }

        let message = try JSONDecoder().decode(MessageResponse.self, from: data)
        if message.stopReason == "refusal" { throw ItemDetectorError.refused }
        guard let text = message.content.first(where: { $0.type == "text" })?.text,
              let json = text.data(using: .utf8) else {
            throw ItemDetectorError.badResponse("The AI returned no item list.")
        }
        return try JSONDecoder().decode(ItemList.self, from: json).items
    }

    private static func body(jpeg: Data, roomName: String, focus: String) -> [String: Any] {
        let focus = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        let intro = """
        This photo was taken in "\(roomName)" during a property walkthrough by a contractor or \
        inspector who documents what is in each room for a quote. Only list things inside \
        this room: leave out anything seen through a doorway, window or opening into another \
        room or outdoors.
        """
        let what = focus.isEmpty ? everything : """
        The inspector only wants these kinds of things documented this time:

        \(focus)

        List only items that fit that description, and leave out everything else, however \
        prominent. Within it, be thorough: include small and partly visible items. If nothing \
        in the photo fits, return an empty list.
        """
        let prompt = intro + "\n\n" + what + "\n\n" + instructions
        let itemSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
                "category": ["type": "string", "enum": RoomItem.categories],
                "condition": ["type": "string", "enum": ItemCondition.allCases.map(\.rawValue)],
                "notes": ["type": "string"],
                "x": ["type": "number"],
                "y": ["type": "number"],
                "left": ["type": "number"],
                "top": ["type": "number"],
                "right": ["type": "number"],
                "bottom": ["type": "number"],
                "opening": ["type": "string", "enum": ["none", "door", "window", "opening"]],
            ],
            "required": ["name", "category", "condition", "notes", "x", "y", "left", "top", "right", "bottom", "opening"],
            "additionalProperties": false,
        ]
        return [
            "model": model,
            "max_tokens": 16000,
            "fallbacks": "default",
            "output_config": [
                "effort": "medium",
                "format": [
                    "type": "json_schema",
                    "schema": [
                        "type": "object",
                        "properties": ["items": ["type": "array", "items": itemSchema]],
                        "required": ["items"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/jpeg",
                            "data": jpeg.base64EncodedString(),
                        ],
                    ],
                    ["type": "text", "text": prompt],
                ],
            ]],
        ]
    }

    /// What to look for when the user has not narrowed it down.
    private static let everything = """
        Be thorough: list every item you can see, including small and partly visible ones. \
        Look for appliances; electrical (each outlet, switch, cover plate, panel, ceiling fan, \
        light fixture, lamp); plumbing fixtures (sinks, faucets, toilets, tubs, water heaters); \
        HVAC (each vent, return grille, thermostat, radiator, unit); network and AV (TVs, \
        speakers, routers, cable jacks); security (cameras, sensors, keypads, doorbells); smoke \
        and CO detectors; windows, doors and blinds; cabinets, counters, shelving and furniture; \
        flooring and wall or ceiling finishes; and any visible damage or wear (water stains, \
        cracks, holes, peeling paint, missing covers). Most room photos show many such items, \
        so do not stop at the most obvious one. Only return an empty list if the photo shows \
        nothing at all, such as a blank wall up close or a blurred image.
        """

    private static let instructions = """
        List every instance separately: three outlets are three items, each with its own \
        position. Only list things that are actually visible.

        For each item give a short name, a category, its apparent condition, a brief note \
        (model, color, size, or problem) or an empty string, x and y: the center of the \
        item, and left, top, right and bottom: the edges of a box that just fits around the \
        item. Give all of these as fractions of the image width and height measured from the \
        top-left corner (0 to 1). Set opening to "door", "window" or "opening" (an open \
        doorway or pass-through) for doors, windows and openings in a wall of this room, so \
        they can be drawn on the floor plan, and "none" for everything else, including door \
        handles, locks and blinds.
        """

    private static func errorMessage(from data: Data, status: Int) -> String {
        if let error = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            if status == 401 { return "Your Claude API key was not accepted. Check it in Settings." }
            return "AI request failed: \(error.error.message)"
        }
        return "AI request failed (HTTP \(status))."
    }

    private struct MessageResponse: Decodable {
        struct Block: Decodable {
            var type: String
            var text: String?
        }
        var content: [Block]
        var stopReason: String?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }
    }

    private struct ItemList: Decodable {
        var items: [DetectedItem]
    }

    private struct ErrorResponse: Decodable {
        struct Detail: Decodable { var message: String }
        var error: Detail
    }
}
