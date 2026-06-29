import Foundation

/// One container as emitted by `docker ps -a --format '{{json .}}'`. Docker uses
/// capitalized keys, so we decode with CodingKeys and expose tidy Swift names.
struct Container: Identifiable, Decodable, Equatable {
    let id: String          // full ID (no-trunc); `id` for Identifiable
    let name: String
    let image: String
    let state: String       // running | exited | paused | created | ...
    let status: String
    let ports: String
    let networks: String
    let createdAt: String

    /// Short 12-char id used by the action/logs subcommands.
    var shortId: String { String(id.prefix(12)) }

    var isRunning: Bool { state.lowercased() == "running" }

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case name = "Names"
        case image = "Image"
        case state = "State"
        case status = "Status"
        case ports = "Ports"
        case networks = "Networks"
        case createdAt = "CreatedAt"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        image = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        ports = try c.decodeIfPresent(String.self, forKey: .ports) ?? ""
        networks = try c.decodeIfPresent(String.self, forKey: .networks) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }
}

/// Live CPU/memory from `docker stats --no-stream --format '{{json .}}'`.
struct ContainerStat: Decodable {
    let id: String
    let cpu: String
    let mem: String
    let memUsage: String

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case cpu = "CPUPerc"
        case mem = "MemPerc"
        case memUsage = "MemUsage"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        cpu = try c.decodeIfPresent(String.self, forKey: .cpu) ?? ""
        mem = try c.decodeIfPresent(String.self, forKey: .mem) ?? ""
        memUsage = try c.decodeIfPresent(String.self, forKey: .memUsage) ?? ""
    }
}
