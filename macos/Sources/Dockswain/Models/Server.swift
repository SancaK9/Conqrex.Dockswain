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

    /// "user@host" — the SSH target argument.
    var target: String {
        user.isEmpty ? host : "\(user)@\(host)"
    }

    /// Stable Keychain account key: target + port.
    var secretAccount: String {
        "\(target):\(port)"
    }
}
