import Foundation
import Security

/// Where RoomScan's cloud lives. RoomScan shares QuoteMaster's Supabase project, so people sign in
/// with their QuoteMaster account. The key below is the public "publishable" key, safe in the app.
enum CloudConfig {
    static let url = URL(string: "https://ebhddtdhnffsyqlzxynj.supabase.co")!
    static let publishableKey = "sb_publishable_t7waCG8V0v17qF6uRwmUBQ_-M2gjh1e"
    static let webApp = URL(string: "https://roomscan-web-theta.vercel.app")!
    static let photoBucket = "roomscan-photos"
}

enum CloudError: LocalizedError {
    case notSignedIn
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to your QuoteMaster account in Settings."
        case .http(_, let message): return message
        case .badResponse: return "The server sent something unexpected."
        }
    }
}

/// The signed-in session, kept in the Keychain.
struct CloudSession: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userID: String
    var email: String
}

enum SessionStore {
    private static let service = "com.roomscan.cloud-session"

    static func load() -> CloudSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(CloudSession.self, from: data)
    }

    static func save(_ session: CloudSession) {
        delete()
        guard let data = try? JSONEncoder().encode(session) else { return }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }

    static var isSignedIn: Bool { load() != nil }
}

/// Hands out a fresh access token, refreshing it when it is about to expire. An actor so two
/// requests at once don't both refresh.
actor CloudTokens {
    static let shared = CloudTokens()

    func accessToken() async throws -> String {
        guard var session = SessionStore.load() else { throw CloudError.notSignedIn }
        if session.expiresAt.timeIntervalSinceNow > 60 { return session.accessToken }
        session = try await CloudAuthAPI.refresh(session.refreshToken)
        SessionStore.save(session)
        return session.accessToken
    }
}

/// Supabase's sign-in endpoints.
enum CloudAuthAPI {
    private struct TokenResponse: Decodable {
        struct User: Decodable { var id: String; var email: String? }
        var access_token: String
        var refresh_token: String
        var expires_in: Double
        var user: User
    }

    static func signIn(email: String, password: String) async throws -> CloudSession {
        try await token(grant: "password", body: ["email": email, "password": password])
    }

    static func refresh(_ refreshToken: String) async throws -> CloudSession {
        do {
            return try await token(grant: "refresh_token", body: ["refresh_token": refreshToken])
        } catch CloudError.http(let status, _) where status == 400 || status == 401 {
            SessionStore.delete()
            throw CloudError.notSignedIn
        }
    }

    static func resetPassword(email: String) async throws {
        var request = URLRequest(url: CloudConfig.url.appendingPathComponent("auth/v1/recover"))
        request.httpMethod = "POST"
        request.setValue(CloudConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email])
        let (data, response) = try await URLSession.shared.data(for: request)
        try CloudAPI.check(data, response)
    }

    private static func token(grant: String, body: [String: String]) async throws -> CloudSession {
        var components = URLComponents(url: CloudConfig.url.appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "grant_type", value: grant)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(CloudConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try CloudAPI.check(data, response)
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        return CloudSession(
            accessToken: token.access_token,
            refreshToken: token.refresh_token,
            expiresAt: Date().addingTimeInterval(token.expires_in),
            userID: token.user.id,
            email: token.user.email ?? ""
        )
    }
}

/// Signed-in calls to the database, storage and server functions.
enum CloudAPI {
    static func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [],
                        json: Any? = nil, body: Data? = nil, contentType: String? = nil,
                        headers: [String: String] = [:], timeout: TimeInterval = 60) async throws -> Data {
        var components = URLComponents(url: CloudConfig.url.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue(CloudConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await CloudTokens.shared.accessToken())", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let body {
            request.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(data, response)
        return data
    }

    static func check(_ data: Data, _ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard !(200..<300).contains(status) else { return }
        if status == 401 { throw CloudError.notSignedIn }
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = (object?["error_description"] ?? object?["msg"] ?? object?["message"] ?? object?["error"]) as? String
        throw CloudError.http(status, message ?? "Request failed (HTTP \(status)).")
    }

    /// Calls the roomscan-ai server function.
    static func ai(_ action: String, _ fields: [String: Any], timeout: TimeInterval = 120) async throws -> Data {
        var payload = fields
        payload["action"] = action
        return try await request("functions/v1/roomscan-ai", method: "POST", json: payload, timeout: timeout)
    }

    private static var tenant: String?
    /// The signed-in user's company in QuoteMaster; photos are stored under it.
    static func tenantID() async throws -> String {
        if let tenant { return tenant }
        let data = try await request("rest/v1/rpc/current_tenant_id", method: "POST", json: [String: Any]())
        guard let id = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String else {
            throw CloudError.http(403, "Your account isn't part of a company in QuoteMaster yet. Finish setting it up there first.")
        }
        tenant = id
        return id
    }

    static func forgetTenant() { tenant = nil }
}
