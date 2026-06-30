import Foundation
import UserNotifications

/// One thing worth telling the user about, detected by diffing two container polls.
struct HealthEvent {
    enum Kind { case crashed, stopped, unhealthy, recovered, restarting }
    let kind: Kind
    let container: String
    let detail: String      // the docker status line, for context
}

/// Turns container state-transitions into macOS notifications. A single shared
/// instance is fed events by every open ServerSession; it decides whether to post
/// based on the user's per-event toggles (read live from UserDefaults, written by
/// AppState). It holds no per-container memory of its own — sessions only hand it
/// genuine transitions, so there's nothing to de-duplicate here.
@MainActor
final class HealthMonitor {
    static let shared = HealthMonitor()
    private init() {}

    /// UNUserNotificationCenter aborts when there's no bundle identifier (e.g. a
    /// bare `swift run`), so notifications are simply a no-op outside the .app.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }
    private var center: UNUserNotificationCenter? { available ? .current() : nil }

    var masterEnabled: Bool { UDefault.bool("notificationsEnabled", false) }

    /// Ask for permission. Called when the user flips the master toggle on.
    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Diff two snapshots (keyed by full container id) and post for each real change.
    /// `previous` being nil means "no baseline yet" → record silently, never notify.
    func process(previous: [String: Container]?, current: [String: Container], server: Server) {
        guard masterEnabled, let previous else { return }
        for event in Self.detect(previous: previous, current: current) {
            post(event, server: server)
        }
    }

    /// Pure transition detection — only containers present in *both* snapshots are
    /// considered, so a freshly-created or removed container never fires.
    static func detect(previous: [String: Container], current: [String: Container]) -> [HealthEvent] {
        var events: [HealthEvent] = []
        for (id, now) in current {
            guard let before = previous[id], before.lifecycle != now.lifecycle else { continue }
            switch now.lifecycle {
            case .stopped:
                let crashed = (now.exitCode ?? 0) != 0
                events.append(.init(kind: crashed ? .crashed : .stopped,
                                    container: now.name, detail: now.status))
            case .unhealthy:
                events.append(.init(kind: .unhealthy, container: now.name, detail: now.status))
            case .restarting:
                events.append(.init(kind: .restarting, container: now.name, detail: now.status))
            case .running:
                if before.lifecycle == .unhealthy {
                    events.append(.init(kind: .recovered, container: now.name, detail: now.status))
                }
            case .starting, .paused:
                break
            }
        }
        return events
    }

    // MARK: - Posting

    private func post(_ event: HealthEvent, server: Server) {
        switch event.kind {
        case .crashed, .stopped:    guard UDefault.bool("notifyOnStop", true) else { return }
        case .unhealthy, .recovered: guard UDefault.bool("notifyOnUnhealthy", true) else { return }
        case .restarting:           guard UDefault.bool("notifyOnRestart", true) else { return }
        }
        guard let center else { return }

        let host = server.label.isEmpty ? server.target : server.label
        let content = UNMutableNotificationContent()
        content.title = Self.title(event.kind, container: event.container)
        content.body = "\(host) · \(event.detail)"
        content.sound = .default
        // One pending request per container+kind: a flapping container coalesces
        // into a single bubble instead of stacking dozens.
        let id = "\(server.id.uuidString):\(event.container):\(event.kind)"
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private static func title(_ kind: HealthEvent.Kind, container: String) -> String {
        switch kind {
        case .crashed:    return "⚠️ \(container) crashed"
        case .stopped:    return "⏹ \(container) stopped"
        case .unhealthy:  return "⚠️ \(container) is unhealthy"
        case .recovered:  return "✅ \(container) recovered"
        case .restarting: return "🔁 \(container) is restarting"
        }
    }
}
