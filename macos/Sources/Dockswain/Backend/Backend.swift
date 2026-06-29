import Foundation

/// Runs the bundled dockswain-mac.sh helper and parses its output. Every public
/// method is async and hops off the main thread; the SwiftUI layer awaits them.
struct Backend {

    /// Settings the app passes down to the helper as environment variables.
    struct Options {
        var dockerCmd: String = "docker"
        var sshTimeout: Int = 5
        var nginxDir: String = "/etc/nginx"
        var sftpTool: String = "auto"      // auto | rsync | scp
    }

    enum BackendError: LocalizedError {
        case scriptMissing
        case launch(String)
        case helper(reason: String)
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .scriptMissing: return "Bundled helper script not found."
            case .launch(let m): return "Could not launch helper: \(m)"
            case .helper(let r): return Backend.humanReason(r)
            case .decode(let m): return "Unexpected helper output: \(m)"
            }
        }
    }

    var options = Options()

    /// Path to dockswain-mac.sh inside the app bundle / build directory.
    static var scriptURL: URL? {
        Bundle.module.url(forResource: "dockswain-mac", withExtension: "sh",
                          subdirectory: "Backend")
            ?? Bundle.module.url(forResource: "dockswain-mac", withExtension: "sh")
    }

    // MARK: - Generic JSON object reply ({"ok":bool,...})

    struct Reply: Decodable {
        let ok: Bool
        let reason: String?
        let version: String?
        let text: String?
        let argv: [String]?
        let pass: Bool?       // nginx-test
        let output: String?   // nginx-test / certbot
        let reclaimed: String?
    }

    // MARK: - Public API

    func probe(_ s: Server) async throws -> String {
        let r = try await runReply(["probe"] + sshArgs(s), env: env(s))
        guard r.ok else { throw BackendError.helper(reason: r.reason ?? "ssh_error") }
        return r.version ?? ""
    }

    /// Full container list (raw docker NDJSON, decoded here).
    func list(_ s: Server) async throws -> [Container] {
        let out = try await runRaw(["list"] + sshArgs(s), env: env(s))
        if let reason = Backend.markerError(out) {
            throw BackendError.helper(reason: reason)
        }
        return Backend.decodeNDJSON(out, as: Container.self)
    }

    func stats(_ s: Server) async throws -> [ContainerStat] {
        let out = try await runRaw(["stats"] + sshArgs(s), env: env(s))
        if Backend.markerError(out) != nil { return [] }   // stats are best-effort
        return Backend.decodeNDJSON(out, as: ContainerStat.self)
    }

    func action(_ act: String, container id: String, on s: Server) async throws {
        let r = try await runReply(["action"] + sshArgs(s) + [act, id], env: env(s))
        guard r.ok else { throw BackendError.helper(reason: r.reason ?? "action_failed") }
    }

    func logs(container id: String, tail: Int, on s: Server) async throws -> String {
        let r = try await runReply(["logs"] + sshArgs(s) + [id, String(tail)], env: env(s))
        guard r.ok else { throw BackendError.helper(reason: r.reason ?? "ssh_error") }
        return r.text ?? ""
    }

    /// The argv for an interactive `ssh ...` to open in Terminal.app.
    func sshArgv(_ s: Server) async throws -> [String] {
        let r = try await runReply(["ssh-cmd"] + sshArgs(s), env: env(s))
        guard r.ok, let argv = r.argv else { throw BackendError.helper(reason: r.reason ?? "ssh_error") }
        return argv
    }

    /// Candidate servers parsed from ~/.ssh/config (key auth assumed).
    func discoverSSHConfigHosts() async throws -> [Server] {
        let out = try await runRaw(["ssh-config-hosts"], env: env(nil))
        guard let line = out.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("[") }),
              let data = line.data(using: .utf8) else { return [] }
        struct Host: Decodable { let label: String; let host: String; let user: String; let port: Int; let key: String }
        let hosts = (try? JSONDecoder().decode([Host].self, from: data)) ?? []
        return hosts.map {
            Server(label: $0.label, user: $0.user, host: $0.host, port: $0.port,
                   auth: .key, keyPath: $0.key)
        }
    }

    /// The argv for an interactive `ssh -t ... docker exec -it <id> <shell>`.
    func execArgv(container id: String, shell: String, on s: Server) async throws -> [String] {
        let r = try await runReply(["exec-cmd"] + sshArgs(s) + [id, shell], env: env(s))
        guard r.ok, let argv = r.argv else { throw BackendError.helper(reason: r.reason ?? "ssh_error") }
        return argv
    }

    // MARK: - Process plumbing

    func sshArgs(_ s: Server) -> [String] {
        [s.target, String(s.port), s.keyPath]
    }

    func env(_ s: Server?) -> [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["CNQ_DOCKER_CMD"] = options.dockerCmd
        e["CNQ_SSH_TIMEOUT"] = String(options.sshTimeout)
        e["CNQ_NGINX_DIR"] = options.nginxDir
        e["CNQ_SFTP_TOOL"] = options.sftpTool
        if let s {
            e["CNQ_AUTH"] = s.auth.rawValue
            e["CNQ_SUDO"] = s.useSudo ? "1" : "0"
            if s.auth == .password {
                e["SSHPASS"] = Keychain.get(account: s.secretAccount) ?? ""
            }
        }
        // Make sure Homebrew paths are visible for docker/jq even when the
        // app is launched from Finder (which gives a minimal PATH).
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        e["PATH"] = (e["PATH"].map { "\($0):\(extra)" }) ?? extra
        return e
    }

    func runRaw(_ args: [String], env: [String: String]) async throws -> String {
        guard let script = Backend.scriptURL else { throw BackendError.scriptMissing }
        return try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path] + args
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()     // swallow stderr; reasons come via stdout JSON
            do {
                try p.run()
            } catch {
                cont.resume(throwing: BackendError.launch(error.localizedDescription))
                return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
        }
    }

    func runReply(_ args: [String], env: [String: String]) async throws -> Reply {
        let out = try await runRaw(args, env: env)
        // helper always prints one JSON object; take the last non-empty line
        guard let line = out.split(whereSeparator: \.isNewline).last(where: { !$0.isEmpty }),
              let data = line.data(using: .utf8) else {
            throw BackendError.decode(out)
        }
        do {
            return try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            throw BackendError.decode(String(line))
        }
    }

    // MARK: - Helpers

    /// Decode an NDJSON blob, skipping lines that fail (a partial line never kills the list).
    static func decodeNDJSON<T: Decodable>(_ text: String, as type: T.Type) -> [T] {
        let dec = JSONDecoder()
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? dec.decode(T.self, from: data)
        }
    }

    /// list/stats prefix a "@@ERR@@ <reason>" line on failure.
    static func markerError(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("@@ERR@@") {
            return line.replacingOccurrences(of: "@@ERR@@", with: "").trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Map a reason code to a readable sentence (mirrors the Linux build's hints).
    static func humanReason(_ r: String) -> String {
        switch r {
        case "ssh_auth": return "SSH authentication failed. Check your key, agent, or password."
        case "no_password": return "No password stored for this server. Set one in Settings."
        case "docker_down": return "Docker daemon is not running on the server."
        case "docker_permission": return "The SSH user can't talk to the Docker socket (try the docker group or sudo docker)."
        case "docker_missing": return "docker is not installed (or not in PATH) on the server."
        case "sudo_password": return "sudo needs a password on this server. Connect as root, or add a NOPASSWD rule for nginx/certbot (passwords can't be typed over this connection)."
        case "permission": return "Permission denied. Enable “Use sudo” for this server, or connect as root."
        case "no_nginx_dir": return "No nginx config directory found on the server."
        case "conflict": return "A file with the opposite (enabled/disabled) state already exists — resolve it on the server first."
        case "bad_name": return "Invalid file name."
        case "create_failed", "write_failed": return "Could not write the file on the server."
        case "delete_failed": return "Could not delete the file on the server."
        case "toggle_failed": return "Could not enable/disable the file on the server."
        case "dns": return "Host could not be resolved."
        case "refused": return "Connection refused."
        case "timeout": return "Connection timed out."
        case "unreachable": return "Host is unreachable."
        case "no_target": return "No server selected."
        default: return "Error: \(r)"
        }
    }
}
