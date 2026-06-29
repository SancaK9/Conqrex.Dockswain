import Foundation

// MARK: - Compose

struct ComposeProject: Identifiable, Decodable, Equatable {
    let name: String
    let status: String
    let configFiles: [String]
    var id: String { name }

    var isRunning: Bool { status.lowercased().contains("running") }

    enum CodingKeys: String, CodingKey {
        case name = "Name", status = "Status", configFiles = "ConfigFiles"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        // docker prints ConfigFiles as a comma-separated string
        let raw = try c.decodeIfPresent(String.self, forKey: .configFiles) ?? ""
        configFiles = raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - Disk usage & cleanup

struct DiskInfo: Decodable, Equatable {
    let size: Int64
    let used: Int64
    let avail: Int64
    let usePct: String
}

struct DfEntry: Identifiable, Decodable, Equatable {
    let type: String
    let count: String
    let active: String
    let size: String
    let reclaimable: String
    var id: String { type }
}

struct ContainerLogFile: Identifiable, Decodable, Equatable {
    let id: String
    let name: String
    let size: Int64       // -1 unreadable, -2 no json-file driver
    let path: String
}

// MARK: - File manager

struct FileEntry: Identifiable, Decodable, Equatable {
    let name: String
    let type: String      // dir | file | link | other
    let size: Int64
    let mtime: Int64
    let mode: String
    var id: String { name }

    var isDir: Bool { type == "dir" }
    var modified: Date { Date(timeIntervalSince1970: TimeInterval(mtime)) }
}

// MARK: - Nginx

struct NginxSite: Identifiable, Decodable, Equatable {
    let name: String      // file/site name (used for enable/disable)
    let path: String      // full path on the server (for view/edit)
    let enabled: Bool
    let tls: Bool
    let serverName: String
    var id: String { path }
    var fileName: String { name }
}

// MARK: - Certbot

struct Cert: Identifiable, Decodable, Equatable {
    let name: String
    let domains: String
    let expiry: String
    var id: String { name }
}

// MARK: - byte formatting helper

enum Bytes {
    static func human(_ n: Int64) -> String {
        if n < 0 { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(n); var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(n) B" : String(format: "%.1f %@", v, units[i])
    }
}
