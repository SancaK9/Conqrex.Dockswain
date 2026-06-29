import Foundation
import SwiftUI
import AppKit

/// Single source of truth for the menubar UI: the server list, the selected
/// server's containers, and the polling loop. Mirrors the role of ServerSession.qml
/// in the Linux build, minus the per-tab plumbing (one active server at a time here).
@MainActor
final class AppState: ObservableObject {
    // Persisted config
    @Published var servers: [Server] = [] { didSet { persistServers() } }
    @Published var selectedServerID: Server.ID? { didSet { onSelectionChange() } }
    @Published var dockerCmd: String = UserDefaults.standard.string(forKey: "dockerCmd") ?? "docker" {
        didSet { UserDefaults.standard.set(dockerCmd, forKey: "dockerCmd"); backend.options.dockerCmd = dockerCmd }
    }
    @Published var refreshInterval: Double = max(2, UserDefaults.standard.double(forKey: "refreshInterval")) {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval"); restartPolling() }
    }
    @Published var statsEnabled: Bool = UserDefaults.standard.bool(forKey: "statsEnabled") {
        didSet { UserDefaults.standard.set(statsEnabled, forKey: "statsEnabled"); if !statsEnabled { statsByID = [:] } }
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

    // Live state
    @Published var containers: [Container] = []
    @Published var statsByID: [String: ContainerStat] = [:]
    @Published var statusMessage: String = "No server selected."
    @Published var isLoading = false
    @Published var serverVersion: String = ""

    private var backend = Backend()
    private var pollTask: Task<Void, Never>?

    var selectedServer: Server? {
        servers.first { $0.id == selectedServerID }
    }

    /// Running / total badge for the menubar title.
    var badge: String {
        guard selectedServer != nil, !containers.isEmpty else { return "" }
        let running = containers.filter(\.isRunning).count
        return "\(running)/\(containers.count)"
    }

    /// A configured Backend instance feature views can use directly.
    func makeBackend() -> Backend {
        var b = Backend()
        b.options.dockerCmd = dockerCmd
        b.options.nginxDir = nginxDir
        return b
    }

    // MARK: - Filtering / grouping / pins

    func isPinned(_ c: Container) -> Bool { pinned.contains(c.name) }

    func togglePin(_ c: Container) {
        if pinned.contains(c.name) { pinned.remove(c.name) } else { pinned.insert(c.name) }
    }

    /// Containers after search + running-only, sorted pinned → running → name.
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

    /// (network, containers) groups, used when groupByNetwork is on.
    var networkGroups: [(network: String, items: [Container])] {
        let items = displayedContainers
        var groups: [String: [Container]] = [:]
        for c in items {
            let net = c.networks.split(separator: ",").first.map(String.init) ?? "—"
            groups[net.isEmpty ? "—" : net, default: []].append(c)
        }
        return groups.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    init() {
        loadServers()
        backend.options.dockerCmd = dockerCmd
        if refreshInterval < 2 { refreshInterval = 5 }
        selectedServerID = servers.first?.id
    }

    // MARK: - Persistence

    private func loadServers() {
        guard let data = UserDefaults.standard.data(forKey: "servers"),
              let decoded = try? JSONDecoder().decode([Server].self, from: data) else { return }
        servers = decoded
    }

    private func persistServers() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: "servers")
        }
    }

    // MARK: - Server CRUD

    func addServer(_ s: Server) {
        servers.append(s)
        if selectedServerID == nil { selectedServerID = s.id }
    }

    func updateServer(_ s: Server) {
        guard let idx = servers.firstIndex(where: { $0.id == s.id }) else { return }
        servers[idx] = s
        if s.id == selectedServerID { onSelectionChange() }
    }

    func removeServer(_ s: Server) {
        Keychain.delete(account: s.secretAccount)
        servers.removeAll { $0.id == s.id }
        if selectedServerID == s.id { selectedServerID = servers.first?.id }
    }

    func importFromSSHConfig() {
        Task {
            guard let discovered = try? await backend.discoverSSHConfigHosts() else { return }
            for host in discovered {
                let dup = servers.contains { $0.host == host.host && $0.port == host.port && $0.user == host.user }
                if !dup { servers.append(host) }
            }
            if selectedServerID == nil { selectedServerID = servers.first?.id }
        }
    }

    // MARK: - Selection + polling

    private func onSelectionChange() {
        containers = []
        statsByID = [:]
        serverVersion = ""
        statusMessage = selectedServer == nil ? "No server selected." : "Connecting…"
        restartPolling()
    }

    private func restartPolling() {
        pollTask?.cancel()
        guard let server = selectedServer else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(server)
                try? await Task.sleep(nanoseconds: UInt64((self?.refreshInterval ?? 5) * 1_000_000_000))
            }
        }
    }

    func refreshNow() {
        guard let server = selectedServer else { return }
        Task { await refresh(server) }
    }

    private func refresh(_ server: Server) async {
        // ignore if the selection changed under us mid-flight
        guard server.id == selectedServerID else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await backend.list(server)
            guard server.id == selectedServerID else { return }
            containers = list.sorted { a, b in
                if a.isRunning != b.isRunning { return a.isRunning }   // running first
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            statusMessage = ""
            if serverVersion.isEmpty {
                serverVersion = (try? await backend.probe(server)) ?? ""
            }
            if statsEnabled {
                if let stats = try? await backend.stats(server), server.id == selectedServerID {
                    var map: [String: ContainerStat] = [:]
                    for st in stats { map[String(st.id.prefix(12))] = st }
                    statsByID = map
                }
            }
        } catch {
            guard server.id == selectedServerID else { return }
            containers = []
            statusMessage = error.localizedDescription
        }
    }

    // MARK: - Actions

    func perform(_ act: String, on container: Container) {
        guard let server = selectedServer else { return }
        Task {
            do {
                try await backend.action(act, container: container.shortId, on: server)
                await refresh(server)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func fetchLogs(_ container: Container) async -> String {
        guard let server = selectedServer else { return "" }
        do {
            return try await backend.logs(container: container.shortId, tail: 400, on: server)
        } catch {
            return error.localizedDescription
        }
    }

    func openExecTerminal(_ container: Container) {
        guard let server = selectedServer else { return }
        Task {
            do {
                let argv = try await backend.execArgv(container: container.shortId, shell: "sh", on: server)
                openTerminal(command: "ssh", argv: argv)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func openSSHTerminal() {
        guard let server = selectedServer else { return }
        Task {
            do {
                let argv = try await backend.sshArgv(server)
                openTerminal(command: "ssh", argv: argv)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Connection test (used by Settings)

    func testConnection(_ s: Server) async -> Result<String, Error> {
        do {
            let v = try await backend.probe(s)
            return .success(v.isEmpty ? "Connected." : "Docker \(v)")
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Terminal.app integration

    /// Open Terminal.app running an interactive ssh command. The argv carries the
    /// shared ControlPath options, so it reuses the warm master socket the poller
    /// keeps authenticated — even a password server connects with no prompt and no
    /// sshpass. (If the master ever expired, ssh just asks for the password in the
    /// Terminal window, the normal way.)
    private func openTerminal(command: String, argv: [String]) {
        let full = ([command] + argv)
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"" +
            full.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") +
            "\"\nend tell"
        runAppleScript(script)
    }

    private func runAppleScript(_ source: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        try? p.run()
    }
}
