import Foundation

/// A configured remote Docker host. Persisted as JSON in UserDefaults; the
/// password (when auth == .password) lives in the macOS Keychain, never here.
struct Server: Identifiable, Codable, Equatable, Hashable {
    enum Auth: String, Codable, CaseIterable {
        case key
        case password
    }

    var id: UUID = UUID()
    var label: String
    var user: String
    var host: String
    var port: Int = 22
    var auth: Auth = .key
    /// Path to a private key for key auth (empty = let ssh pick from agent/config).
    var keyPath: String = ""

    /// Run privileged remote ops (nginx, certbot, conf.d edits) via `sudo -n`. Needs
    /// NOPASSWD or a root login; leave off when the SSH user is already root.
    var useSudo: Bool = false

    /// "user@host" — the SSH target argument.
    var target: String {
        user.isEmpty ? host : "\(user)@\(host)"
    }

    /// Stable Keychain account key: target + port.
    var secretAccount: String {
        "\(target):\(port)"
    }
}

extension Server {
    enum CodingKeys: String, CodingKey {
        case id, label, user, host, port, auth, keyPath, useSudo
    }

    // Decode tolerantly so a server persisted by an older build (no `useSudo` key, and
    // historically optional fields) still loads instead of wiping the saved list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        auth = try c.decodeIfPresent(Auth.self, forKey: .auth) ?? .key
        keyPath = try c.decodeIfPresent(String.self, forKey: .keyPath) ?? ""
        useSudo = try c.decodeIfPresent(Bool.self, forKey: .useSudo) ?? false
    }
}
