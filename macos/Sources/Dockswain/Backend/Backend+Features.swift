import Foundation

/// Typed wrappers over the extra helper subcommands (compose, disk, file manager,
/// nginx, certbot). Each decodes the helper's JSON into a model.
extension Backend {

    private func decodeField<T: Decodable>(_ json: String, key: String, as type: T.Type) throws -> T {
        guard let data = lastJSONLine(json) else { throw BackendError.decode(json) }
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any]
        if let ok = obj?["ok"] as? Bool, ok == false {
            throw BackendError.helper(reason: (obj?["reason"] as? String) ?? "error")
        }
        guard let field = obj?[key] else { throw BackendError.decode(json) }

        // Scalars are handled directly: JSONSerialization.data(withJSONObject:) throws an
        // *Objective-C* exception (uncatchable by `try`) on a non-container top level, which
        // is what crashed the app on string fields like nginx "dir" / sftp "home".
        if let v = field as? String, let out = v as? T { return out }
        if let n = field as? NSNumber {
            if type == Int64.self,  let out = n.int64Value as? T { return out }
            if type == Int.self,    let out = n.intValue   as? T { return out }
            if type == Double.self, let out = n.doubleValue as? T { return out }
            if type == Bool.self,   let out = n.boolValue  as? T { return out }
        }
        // Arrays / dictionaries: safe to re-serialize and decode.
        let fieldData = try JSONSerialization.data(withJSONObject: field, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(T.self, from: fieldData)
    }

    private func lastJSONLine(_ s: String) -> Data? {
        s.split(whereSeparator: \.isNewline).last { $0.hasPrefix("{") || $0.hasPrefix("[") }?
            .data(using: .utf8)
    }

    private func okOrThrow(_ args: [String], on s: Server) async throws {
        let r = try await runReply(args, env: env(s))
        guard r.ok else { throw BackendError.helper(reason: r.reason ?? "error") }
    }

    // MARK: - Stats (live CPU/mem)
    // stats(_:) lives in Backend.swift already.

    // MARK: - Compose

    func composeProjects(_ s: Server) async throws -> [ComposeProject] {
        let out = try await runRaw(["compose"] + sshArgs(s), env: env(s))
        return try decodeField(out, key: "projects", as: [ComposeProject].self)
    }

    func composeAction(_ act: String, configFiles: [String], on s: Server) async throws {
        let csv = configFiles.joined(separator: ",")
        try await okOrThrow(["compose-action"] + sshArgs(s) + [act, csv], on: s)
    }

    // MARK: - Disk & cleanup

    func disk(_ s: Server) async throws -> (DiskInfo, [DfEntry]) {
        let out = try await runRaw(["disk"] + sshArgs(s), env: env(s))
        let info = try decodeField(out, key: "disk", as: DiskInfo.self)
        let df = try decodeField(out, key: "df", as: [DfEntry].self)
        return (info, df)
    }

    func prune(_ what: String, on s: Server) async throws -> String {
        let r = try await runReply(["prune"] + sshArgs(s) + [what], env: env(s))
        guard r.ok else { throw BackendError.helper(reason: r.reason ?? "prune_failed") }
        return r.reclaimed ?? ""
    }

    func containerLogFiles(_ s: Server) async throws -> (logs: [ContainerLogFile], total: Int64) {
        let out = try await runRaw(["container-logs"] + sshArgs(s), env: env(s))
        let logs = try decodeField(out, key: "logs", as: [ContainerLogFile].self)
        let total = (try? decodeField(out, key: "total", as: Int64.self)) ?? 0
        return (logs, total)
    }

    func truncateLog(container id: String, on s: Server) async throws {
        try await okOrThrow(["truncate-log"] + sshArgs(s) + [id], on: s)
    }

    // MARK: - File manager (remote)

    func sftpHome(_ s: Server) async throws -> String {
        let out = try await runRaw(["sftp-home"] + sshArgs(s), env: env(s))
        return try decodeField(out, key: "home", as: String.self)
    }

    func sftpList(_ path: String, on s: Server) async throws -> [FileEntry] {
        let out = try await runRaw(["sftp-list"] + sshArgs(s) + [path], env: env(s))
        return try decodeField(out, key: "entries", as: [FileEntry].self)
    }

    func sftpMkdir(_ path: String, on s: Server) async throws {
        try await okOrThrow(["sftp-mkdir"] + sshArgs(s) + [path], on: s)
    }
    func sftpRename(_ from: String, to: String, on s: Server) async throws {
        try await okOrThrow(["sftp-rename"] + sshArgs(s) + [from, to], on: s)
    }
    func sftpDelete(_ path: String, recursive: Bool, on s: Server) async throws {
        try await okOrThrow(["sftp-delete"] + sshArgs(s) + [path, recursive ? "1" : "0"], on: s)
    }

    // MARK: - Transfers

    func upload(local: String, remote: String, recursive: Bool, on s: Server) async throws {
        try await okOrThrow(["scp-up"] + sshArgs(s) + [local, remote, recursive ? "1" : "0"], on: s)
    }
    func download(remote: String, local: String, recursive: Bool, on s: Server) async throws {
        try await okOrThrow(["scp-down"] + sshArgs(s) + [remote, local, recursive ? "1" : "0"], on: s)
    }

    // MARK: - Read / write remote file

    func readFile(_ path: String, on s: Server) async throws -> String {
        let r = try await runReply(["readfile"] + sshArgs(s) + [path], env: env(s))
        guard r.ok else { throw BackendError.helper(reason: r.reason ?? "not_found") }
        return r.text ?? ""
    }

    func writeFile(_ path: String, content: String, on s: Server) async throws {
        let b64 = Data(content.utf8).base64EncodedString()
        try await okOrThrow(["writefile"] + sshArgs(s) + [path, b64], on: s)
    }

    // MARK: - Nginx

    func nginxSites(_ s: Server) async throws -> (dir: String, sites: [NginxSite]) {
        let out = try await runRaw(["nginx-list"] + sshArgs(s), env: env(s))
        let dir = (try? decodeField(out, key: "dir", as: String.self)) ?? "/etc/nginx"
        let sites = try decodeField(out, key: "sites", as: [NginxSite].self)
        return (dir, sites)
    }

    func nginxToggle(_ act: String, fileName: String, on s: Server) async throws {
        try await okOrThrow(["nginx-toggle"] + sshArgs(s) + [act, fileName], on: s)
    }

    func nginxNew(name: String, config: String, on s: Server) async throws {
        let b64 = Data(config.utf8).base64EncodedString()
        try await okOrThrow(["nginx-new"] + sshArgs(s) + [name, b64], on: s)
    }

    /// Returns (pass, output).
    func nginxTest(_ s: Server) async throws -> (Bool, String) {
        let r = try await runReply(["nginx-test"] + sshArgs(s), env: env(s))
        return (r.pass ?? false, r.output ?? "")
    }

    func nginxReload(_ s: Server) async throws {
        try await okOrThrow(["nginx-reload"] + sshArgs(s), on: s)
    }

    // MARK: - Nginx conf.d snippets

    func nginxConfd(_ s: Server) async throws -> (dir: String, files: [ConfdFile]) {
        let out = try await runRaw(["nginx-confd-list"] + sshArgs(s), env: env(s))
        let dir = (try? decodeField(out, key: "dir", as: String.self)) ?? "\(options.nginxDir)/conf.d"
        let files = try decodeField(out, key: "files", as: [ConfdFile].self)
        return (dir, files)
    }

    func nginxConfdToggle(_ act: String, name: String, on s: Server) async throws {
        try await okOrThrow(["nginx-confd-toggle"] + sshArgs(s) + [act, name], on: s)
    }

    func nginxConfdDelete(_ name: String, on s: Server) async throws {
        try await okOrThrow(["nginx-confd-del"] + sshArgs(s) + [name], on: s)
    }

    // MARK: - Certbot

    func certbotList(_ s: Server) async throws -> [Cert] {
        let out = try await runRaw(["certbot-list"] + sshArgs(s), env: env(s))
        return try decodeField(out, key: "certs", as: [Cert].self)
    }

    /// Returns the certbot output; throws with the reason on failure.
    func certbotIssue(domains: [String], redirect: Bool, on s: Server) async throws -> String {
        let r = try await runReply(["certbot-issue"] + sshArgs(s) + [domains.joined(separator: ","), redirect ? "1" : "0"], env: env(s))
        guard r.ok else { throw BackendError.helper(reason: r.reason ?? "certbot failed") }
        return r.output ?? ""
    }
}
