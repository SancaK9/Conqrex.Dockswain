import Foundation
import SwiftUI

/// One live connection to a server: its own container list, stats, status and
/// polling loop. Several can run at once (one per open tab), each refreshing
/// independently. Only the active tab fetches CPU/mem stats (they're slower).
@MainActor
final class ServerSession: ObservableObject, Identifiable {
    let server: Server
    nonisolated var id: UUID { server.id }

    @Published var containers: [Container] = []
    @Published var statsByID: [String: ContainerStat] = [:]
    @Published var statusMessage = "Connecting…"
    @Published var serverVersion = ""
    @Published var isLoading = false

    private var backend: Backend
    private var pollTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var refreshInterval: Double
    private var statsInterval: Double
    private(set) var statsEnabled = false

    init(server: Server, dockerCmd: String, nginxDir: String, refreshInterval: Double,
         statsInterval: Double = 2, sshTimeout: Int = 5) {
        self.server = server
        self.refreshInterval = refreshInterval
        self.statsInterval = statsInterval
        var b = Backend()
        b.options.dockerCmd = dockerCmd
        b.options.nginxDir = nginxDir
        b.options.sshTimeout = sshTimeout
        self.backend = b
    }

    /// Running / total badge for this tab.
    var badge: String {
        guard !containers.isEmpty else { return "" }
        return "\(containers.filter(\.isRunning).count)/\(containers.count)"
    }

    // MARK: - Lifecycle

    func start() { restartPolling() }
    func stop() { pollTask?.cancel(); pollTask = nil; statsTask?.cancel(); statsTask = nil }

    func setRefreshInterval(_ v: Double) {
        guard v != refreshInterval else { return }
        refreshInterval = v
        if pollTask != nil { restartPolling() }
    }

    func setStatsInterval(_ v: Double) {
        guard v != statsInterval else { return }
        statsInterval = v
        if statsEnabled { restartStatsPolling() }
    }

    func setStatsEnabled(_ on: Bool) {
        guard on != statsEnabled else { return }
        statsEnabled = on
        if on { restartStatsPolling() }
        else { statsTask?.cancel(); statsTask = nil; statsByID = [:] }
    }

    func setDockerCmd(_ cmd: String) { backend.options.dockerCmd = cmd }

    func refreshNow() { Task { await refresh() } }

    private func restartPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let interval = self?.refreshInterval ?? 5
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// Stats poll independently of the container list, at their own interval, so
    /// CPU/mem can update faster (or slower) than the list without coupling them.
    private func restartStatsPolling() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchStats()
                let interval = self?.statsInterval ?? 2
                try? await Task.sleep(nanoseconds: UInt64(max(1, interval) * 1_000_000_000))
            }
        }
    }

    private func fetchStats() async {
        guard statsEnabled, let stats = try? await backend.stats(server), !Task.isCancelled else { return }
        var map: [String: ContainerStat] = [:]
        for st in stats { map[String(st.id.prefix(12))] = st }
        statsByID = map
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await backend.list(server)
            if Task.isCancelled { return }
            containers = list.sorted { a, b in
                if a.isRunning != b.isRunning { return a.isRunning }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            statusMessage = ""
            if serverVersion.isEmpty {
                serverVersion = (try? await backend.probe(server)) ?? ""
            }
        } catch {
            if Task.isCancelled { return }
            containers = []
            statusMessage = error.localizedDescription
        }
    }

    // MARK: - Actions

    func perform(_ act: String, on container: Container) {
        Task {
            do {
                try await backend.action(act, container: container.shortId, on: server)
                await refresh()
            } catch { statusMessage = error.localizedDescription }
        }
    }

    func fetchLogs(_ container: Container, tail: Int = 400) async -> String {
        do { return try await backend.logs(container: container.shortId, tail: tail, on: server) }
        catch { return error.localizedDescription }
    }
}
