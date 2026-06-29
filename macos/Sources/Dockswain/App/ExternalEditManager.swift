import Foundation
import AppKit

/// Edit a remote file in the system text editor with live save-back — the macOS
/// take on the Linux build's `edit` (Kate + watcher). It pulls the file to a temp
/// copy over the warm SSH connection, opens it with `open -t`, then polls the temp
/// every ~1.5s and writes it back to the server whenever its contents change.
@MainActor
final class ExternalEditManager: ObservableObject {
    struct Session: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let remotePath: String
        var savedAt: Date?       // last successful push-back
        var error: String?
        static func == (a: Session, b: Session) -> Bool { a.id == b.id }
    }

    @Published private(set) var sessions: [Session] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// Pull `remotePath` to a temp file, open it, and start watching for saves.
    /// `app` (e.g. "Visual Studio Code") opens with `open -a`; empty uses the
    /// default text editor via `open -t`.
    func open(remotePath: String, name: String, app: String = "",
              backend: Backend, server: Server) async {
        // Avoid opening the same remote file twice.
        if sessions.contains(where: { $0.remotePath == remotePath }) { return }
        guard let content = try? await backend.readFile(remotePath, on: server) else { return }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dockswain-edit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(name)")
        do { try content.write(to: url, atomically: true, encoding: .utf8) }
        catch { return }

        // open -t opens in the user's default *text* editor and returns immediately;
        // open -a <App> targets a specific editor. Either way `open` returns at once.
        let trimmed = app.trimmingCharacters(in: .whitespaces)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = trimmed.isEmpty ? ["-t", url.path] : ["-a", trimmed, url.path]
        try? p.run()

        let session = Session(name: name, remotePath: remotePath)
        sessions.append(session)
        let id = session.id
        tasks[id] = Task { [weak self] in
            await self?.watch(id: id, url: url, remotePath: remotePath, backend: backend, server: server,
                              initial: content)
        }
    }

    func stop(_ id: UUID) {
        tasks[id]?.cancel(); tasks[id] = nil
        sessions.removeAll { $0.id == id }
    }

    func stopAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll(); sessions.removeAll()
    }

    // MARK: - Watcher

    private func watch(id: UUID, url: URL, remotePath: String, backend: Backend, server: Server,
                       initial: String) async {
        var last = initial
        // Keep watching until cancelled (the user presses Stop) or the temp vanishes.
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { break }
            guard let cur = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard cur != last else { continue }
            last = cur
            do {
                try await backend.writeFile(remotePath, content: cur, on: server)
                update(id) { $0.savedAt = Date(); $0.error = nil }
            } catch {
                update(id) { $0.error = error.localizedDescription }
            }
        }
        try? FileManager.default.removeItem(at: url)
    }

    private func update(_ id: UUID, _ mutate: (inout Session) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&sessions[i])
    }
}
