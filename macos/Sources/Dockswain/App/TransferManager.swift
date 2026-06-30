import Foundation

/// One queued file transfer (upload or download), updated live from the helper's
/// streaming `xfer-run` events.
struct Transfer: Identifiable, Equatable {
    enum State: Equatable { case running, done, error, cancelled }

    let id = UUID()
    let name: String
    let up: Bool              // true = local → remote
    var tool: String = ""     // "rsync" | "scp"
    var pct: Double = 0       // 0–100, or -1 when the tool can't report progress
    var rate: String = ""
    var state: State = .running
    var detail: String = ""

    var isFinished: Bool { state != .running }
    var indeterminate: Bool { pct < 0 && state == .running }
}

/// Owns the live queue of transfers. Each transfer is a long-running `xfer-run`
/// process whose stdout we read line-by-line; cancelling terminates the process
/// (rsync/scp dies with it). Lives on AppState so it survives screen navigation.
@MainActor
final class TransferManager: ObservableObject {
    @Published private(set) var transfers: [Transfer] = []

    private var procs: [UUID: Process] = [:]
    private var buffers: [UUID: String] = [:]

    var hasActive: Bool { transfers.contains { !$0.isFinished } }

    /// One streamed JSON event line from the helper.
    private struct Event: Decodable {
        let event: String
        let tool: String?
        let pct: Double?
        let rate: String?
        let code: String?
    }

    // MARK: - Lifecycle

    func start(up: Bool, name: String, src: String, dst: String, recursive: Bool,
               syncMode: String, backend: Backend, server: Server) {
        guard let cmd = backend.transferCommand(up: up, src: src, dst: dst,
                  recursive: recursive, syncMode: syncMode, on: server) else { return }

        let t = Transfer(name: name, up: up)
        let id = t.id
        transfers.insert(t, at: 0)

        let p = Process()
        p.executableURL = cmd.exe
        p.arguments = cmd.args
        p.environment = cmd.env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()       // diagnostics go to stdout events; swallow stderr

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            guard let self else { return }
            Task { @MainActor in self.ingest(id: id, chunk: chunk) }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let signalled = proc.terminationReason == .uncaughtSignal
            guard let self else { return }
            Task { @MainActor in self.terminated(id: id, status: status, signalled: signalled) }
        }

        do { try p.run(); procs[id] = p }
        catch { update(id) { $0.state = .error; $0.detail = error.localizedDescription } }
    }

    func cancel(_ id: UUID) {
        procs[id]?.terminate()
        update(id) { if !$0.isFinished { $0.state = .cancelled } }
    }

    /// Remove a finished transfer from the list (no-op while it is still running).
    func clear(_ id: UUID) {
        guard let t = transfers.first(where: { $0.id == id }), t.isFinished else { return }
        transfers.removeAll { $0.id == id }
        cleanup(id)
    }

    func clearFinished() {
        for t in transfers where t.isFinished { cleanup(t.id) }
        transfers.removeAll { $0.isFinished }
    }

    // MARK: - Streaming

    private func ingest(id: UUID, chunk: String) {
        var buf = (buffers[id] ?? "") + chunk
        while let nl = buf.firstIndex(of: "\n") {
            let line = String(buf[..<nl])
            buf = String(buf[buf.index(after: nl)...])
            handle(id: id, line: line)
        }
        buffers[id] = buf
    }

    private func handle(id: UUID, line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let ev = try? JSONDecoder().decode(Event.self, from: data) else { return }
        switch ev.event {
        case "start":
            update(id) { $0.tool = ev.tool ?? ""; if $0.state == .running { $0.pct = 0 } }
        case "progress":
            update(id) {
                guard $0.state == .running else { return }
                if let p = ev.pct { $0.pct = p }
                if let r = ev.rate { $0.rate = r }
            }
        case "done":
            update(id) { if $0.state == .running { $0.state = .done; $0.pct = 100 } }
        case "error":
            update(id) {
                guard $0.state == .running else { return }
                let code = ev.code ?? ""
                if code == "cancelled" { $0.state = .cancelled }
                else { $0.state = .error; $0.detail = Self.reason(code) }
            }
        default: break
        }
    }

    /// Process exited: settle anything still "running" (a signal means we cancelled it).
    private func terminated(id: UUID, status: Int32, signalled: Bool) {
        update(id) {
            guard $0.state == .running else { return }
            if signalled || status != 0 { $0.state = signalled ? .cancelled : .error
                                          if $0.detail.isEmpty && !signalled { $0.detail = "exit \(status)" } }
            else { $0.state = .done; $0.pct = 100 }
        }
        cleanup(id)
    }

    private func cleanup(_ id: UUID) {
        if let p = procs[id] { (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
        procs[id] = nil
        buffers[id] = nil
    }

    private func update(_ id: UUID, _ mutate: (inout Transfer) -> Void) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        mutate(&transfers[i])
    }

    private static func reason(_ code: String) -> String {
        switch code {
        case "no_path":        return "Missing path"
        case "bad_direction":  return "Bad direction"
        case "23", "24":       return "Some files were not transferred"
        default:               return "Transfer failed (\(code))"
        }
    }
}
