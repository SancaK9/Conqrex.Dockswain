import Foundation
import Security

/// Thin wrapper over the macOS Keychain for per-server SSH passwords. This is the
/// macOS counterpart to the Linux build's `secret-tool` / KWallet usage: the
/// password is stored as a generic password under a fixed service, keyed by the
/// server's "user@host:port". It never lands in a config file or on a command line.
///
/// A process-wide in-memory cache fronts every read. Without it the app would hit
/// the Keychain on *every* poll (a few times a second across servers), and macOS
/// shows its "allow access?" prompt on each hardware read — a prompt storm. With the
/// cache the real Keychain is touched at most once per server per launch, so after
/// you click "Always Allow" once it stays quiet. Reads from arbitrary threads (the
/// backend runs off the main actor), so the cache is lock-guarded.
enum Keychain {
    static let service = "com.conqrex.dockswain"

    private static let lock = NSLock()
    private static var cache: [String: String] = [:]

    private static func cached(_ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return cache[account]
    }
    private static func store(_ account: String, _ value: String?) {
        lock.lock(); defer { lock.unlock() }
        cache[account] = value
    }

    @discardableResult
    static func set(_ password: String, account: String) -> Bool {
        let data = Data(password.utf8)
        delete(account: account)                 // upsert cleanly
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let ok = SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        if ok { store(account, password) }       // prime the cache so no read-back prompt
        return ok
    }

    static func get(account: String) -> String? {
        if let hit = cached(account) { return hit }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        store(account, str)
        return str
    }

    /// Cheap existence check that never triggers an ACL prompt: it asks only for the
    /// item's attributes (no data), so macOS doesn't gate it behind "allow access?".
    static func has(account: String) -> Bool {
        if cached(account) != nil { return true }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        store(account, nil)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
