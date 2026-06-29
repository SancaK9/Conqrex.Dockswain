import Foundation
import SwiftUI
import AppKit
import Combine

/// App-wide state: the configured servers, settings, and the set of *open* server
/// tabs (ServerSessions). The container list / stats / status shown in the UI are a
/// facade over the active tab, so the views keep reading `state.containers` etc.
@MainActor
final class AppState: ObservableObject {
    // Persisted config
    @Published var servers: [Server] = [] { didSet { persistServers() } }
    @Published var dockerCmd: String = UserDefaults.standard.string(forKey: "dockerCmd") ?? "docker" {
        didSet { UserDefaults.standard.set(dockerCmd, forKey: "dockerCmd"); sessions.forEach { $0.setDockerCmd(dockerCmd) } }
    }
    @Published var refreshInterval: Double = max(2, UserDefaults.standard.double(forKey: "refreshInterval")) {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval"); sessions.forEach { $0.setRefreshInterval(refreshInterval) } }
    }
    @Published var statsEnabled: Bool = UserDefaults.standard.bool(forKey: "statsEnabled") {
        didSet { UserDefaults.standard.set(statsEnabled, forKey: "statsEnabled"); applyStatsGating() }
    }
    @Published var groupByNetwork: Bool = UserDefaults.standard.bool(forKey: "groupByNetwork") {
        didSet { UserDefaults.standard.set(groupByNetwork, forKey: "groupByNetwork") }
    }
    @Published var nginxDir: String = UserDefaults.standard.string(forKey: "nginxDir") ?? "/etc/nginx" {
        didSet { UserDefaults.standard.set(nginxDir, forKey: "nginxDir") }
    }

    // Filtering (session-only)
    @Published var searchText: String = ""
    @Published var runningOnly: Bool = false

    // Pins (persisted, by container name)
    @Published var pinned: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "pinned") ?? []) {
        didSet { UserDefaults.standard.set(Array(pinned), forKey: "pinned") }
    }

    // Open tabs
    @Published var sessions: [ServerSession] = []
    @Published var activeID: UUID? { didSet { onActiveChange() } }

    private var sessionCancellables: [UUID: AnyCancellable] = [:]

    var active: ServerSession? { sessions.first { $0.id == activeID } }
    var selectedServer: Server? { active?.server }

    // MARK: - Facade over the active session (views read these unchanged)

    var containers: [Container] { active?.containers ?? [] }
    var statsByID: [String: ContainerStat] { active?.statsByID ?? [:] }
    var isLoading: Bool { active?.isLoading ?? false }
    var serverVersion: String { active?.serverVersion ?? "" }
    var statusMessage: String {
        if sessions.isEmpty { return servers.isEmpty ? "No servers yet." : "No server open." }
        return active?.statusMessage ?? ""
    }
    var badge: String { active?.badge ?? "" }

    /// Configured servers that aren't open yet (for the "+" menu).
    var unopenedServers: [Server] { servers.filter { s in !sessions.contains { $0.id == s.id } } }

    func makeBackend() -> Backend {
        var b = Backend(); b.options.dockerCmd = dockerCmd; b.options.nginxDir = nginxDir
        return b
    }

    // MARK: - Filtering / grouping / pins

    func isPinned(_ c: Container) -> Bool { pinned.contains(c.name) }
    func togglePin(_ c: Container) {
        if pinned.contains(c.name) { pinned.remove(c.name) } else { pinned.insert(c.name) }
    }

    var displayedContainers: [Container] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return containers.filter { c in
            if runningOnly && !c.isRunning { return false }
            if q.isEmpty { return true }
            return c.name.lowercased().contains(q)
                || c.image.lowercased().contains(q)
                || c.state.lowercased().contains(q)
        }.sorted { a, b in
            let pa = isPinned(a), pb = isPinned(b)
            if pa != pb { return pa }
            if a.isRunning != b.isRunning { return a.isRunning }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    var hiddenCount: Int { containers.count - displayedContainers.count }

    /// Swarm tasks sit on ingress + docker_gwbridge plus their app network, which
    /// makes them jump between polls; group them under the app network instead so
    /// they stay put. Only those two swarm-infra networks are skipped — a plain
    /// container on `bridge`/`host` still groups under that.
    private static let swarmInfra: Set<String> = ["ingress", "docker_gwbridge"]
    private func appNetwork(_ networks: String) -> String {
        let parts = networks.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let app = parts.first(where: { !AppState.swarmInfra.contains($0) }) { return app }
        return parts.first ?? "—"
    }

    var networkGroups: [(network: String, items: [Container])] {
        var groups: [String: [Container]] = [:]
        for c in displayedContainers {
            groups[appNetwork(c.networks), default: []].append(c)
        }
        return groups.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    init() {
        loadServers()
        if refreshInterval < 2 { refreshInterval = 5 }
        restoreOpenTabs()
    }

    // MARK: - Persistence

    private func loadServers() {
        guard let data = UserDefaults.standard.data(forKey: "servers"),
              let decoded = try? JSONDecoder().decode([Server].self, from: data) else { return }
        servers = decoded
    }
    private func persistServers() {
        if let data = try? JSONEncoder().encode(servers) { UserDefaults.standard.set(data, forKey: "servers") }
    }
    private func persistOpenTabs() {
        UserDefaults.standard.set(sessions.map { $0.id.uuidString }, forKey: "openTabs")
        UserDefaults.standard.set(activeID?.uuidString, forKey: "activeTab")
    }
    private func restoreOpenTabs() {
        let ids = (UserDefaults.standard.stringArray(forKey: "openTabs") ?? []).compactMap(UUID.init)
        for id in ids { if let s = servers.first(where: { $0.id == id }) { open(s, makeActive: false, persist: false) } }
        if sessions.isEmpty, let first = servers.first { open(first, makeActive: false, persist: false) }
        let saved = UserDefaults.standard.string(forKey: "activeTab").flatMap(UUID.init)
        activeID = (saved.flatMap { id in sessions.first { $0.id == id }?.id }) ?? sessions.first?.id
        persistOpenTabs()
    }

    // MARK: - Tabs

    func open(_ server: Server, makeActive: Bool = true, persist: Bool = true) {
        if !sessions.contains(where: { $0.id == server.id }) {
            let session = ServerSession(server: server, dockerCmd: dockerCmd,
                                        nginxDir: nginxDir, refreshInterval: refreshInterval)
            sessions.append(session)
            sessionCancellables[session.id] = session.objectWillChange.sink { [weak self] in
                self?.objectWillChange.send()
            }
            session.start()
        }
        if makeActive { activeID = server.id }
        applyStatsGating()
        if persist { persistOpenTabs() }
    }

    func closeTab(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].stop()
        sessionCancellables[id] = nil
        sessions.remove(at: idx)
        if activeID == id {
            activeID = sessions.indices.contains(idx) ? sessions[idx].id : sessions.last?.id
        }
        applyStatsGating()
        persistOpenTabs()
    }

    func setActive(_ id: UUID) { activeID = id }

    private func onActiveChange() {
        applyStatsGating()
        persistOpenTabs()
        objectWillChange.send()
    }

    /// Only the active tab fetches stats (and only when the setting is on).
    private func applyStatsGating() {
        for s in sessions { s.setStatsEnabled(statsEnabled && s.id == activeID) }
        active?.refreshNow()
    }

    func refreshNow() { active?.refreshNow() }

    // MARK: - Server CRUD

    func addServer(_ s: Server) { servers.append(s) }

    func updateServer(_ s: Server) {
        guard let idx = servers.firstIndex(where: { $0.id == s.id }) else { return }
        servers[idx] = s
        // if it's open, restart its session with the new settings
        if sessions.contains(where: { $0.id == s.id }) {
            let wasActive = activeID == s.id
            closeTab(s.id)
            open(s, makeActive: wasActive)
        }
    }

    func removeServer(_ s: Server) {
        Keychain.delete(account: s.secretAccount)
        if sessions.contains(where: { $0.id == s.id }) { closeTab(s.id) }
        servers.removeAll { $0.id == s.id }
    }

    func importFromSSHConfig() {
        Task {
            guard let discovered = try? await makeBackend().discoverSSHConfigHosts() else { return }
            for host in discovered {
                let dup = servers.contains { $0.host == host.host && $0.port == host.port && $0.user == host.user }
                if !dup { servers.append(host) }
            }
            if sessions.isEmpty, let first = servers.first { open(first) }
        }
    }

    // MARK: - Actions (delegate to the active session)

    func perform(_ act: String, on container: Container) { active?.perform(act, on: container) }
    func fetchLogs(_ container: Container) async -> String { await active?.fetchLogs(container) ?? "" }

    func openExecTerminal(_ container: Container) {
        guard let server = selectedServer else { return }
        Task {
            do {
                let argv = try await makeBackend().execArgv(container: container.shortId, shell: "sh", on: server)
                openTerminal(command: "ssh", argv: argv)
            } catch { /* surfaced via session status on next poll */ }
        }
    }

    func openSSHTerminal() {
        guard let server = selectedServer else { return }
        Task {
            do {
                let argv = try await makeBackend().sshArgv(server)
                openTerminal(command: "ssh", argv: argv)
            } catch { }
        }
    }

    func testConnection(_ s: Server) async -> Result<String, Error> {
        do {
            let v = try await makeBackend().probe(s)
            return .success(v.isEmpty ? "Connected." : "Docker \(v)")
        } catch { return .failure(error) }
    }

    // MARK: - Terminal.app integration

    private func openTerminal(command: String, argv: [String]) {
        let full = ([command] + argv)
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"" +
            full.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") +
            "\"\nend tell"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}
