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
    private var refreshInterval: Double
    private(set) var statsEnabled = false

    init(server: Server, dockerCmd: String, nginxDir: String, refreshInterval: Double) {
        self.server = server
        self.refreshInterval = refreshInterval
        var b = Backend()
        b.options.dockerCmd = dockerCmd
        b.options.nginxDir = nginxDir
        self.backend = b
    }

    /// Running / total badge for this tab.
    var badge: String {
        guard !containers.isEmpty else { return "" }
        return "\(containers.filter(\.isRunning).count)/\(containers.count)"
    }

    // MARK: - Lifecycle

    func start() { restartPolling() }
    func stop() { pollTask?.cancel(); pollTask = nil }

    func setRefreshInterval(_ v: Double) {
        guard v != refreshInterval else { return }
        refreshInterval = v
        if pollTask != nil { restartPolling() }
    }

    func setStatsEnabled(_ on: Bool) {
        statsEnabled = on
        if !on { statsByID = [:] }
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
            if statsEnabled, let stats = try? await backend.stats(server), !Task.isCancelled {
                var map: [String: ContainerStat] = [:]
                for st in stats { map[String(st.id.prefix(12))] = st }
                statsByID = map
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

    func fetchLogs(_ container: Container) async -> String {
        do { return try await backend.logs(container: container.shortId, tail: 400, on: server) }
        catch { return error.localizedDescription }
    }
}
