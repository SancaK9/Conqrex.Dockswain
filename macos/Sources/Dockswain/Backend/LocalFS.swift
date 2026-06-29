import Foundation

/// Lists and mutates files on the local Mac for the file manager's local pane.
/// Done natively (FileManager) rather than via `find -printf`, which BSD lacks.
enum LocalFS {
    static func home() -> String { NSHomeDirectory() }

    static func list(_ path: String) -> [FileEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        return names.compactMap { name -> FileEntry? in
            let full = (path as NSString).appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: full) else { return nil }
            let type: String
            switch attrs[.type] as? FileAttributeType {
            case .typeDirectory?: type = "dir"
            case .typeSymbolicLink?: type = "link"
            case .typeRegular?: type = "file"
            default: type = "other"
            }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = Int64((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
            let perms = (attrs[.posixPermissions] as? NSNumber).map { String($0.intValue, radix: 8) } ?? ""
            return FileEntry(name: name, type: type, size: size, mtime: mtime, mode: perms)
        }
    }

    static func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    }
    static func rename(_ from: String, to: String) throws {
        try FileManager.default.moveItem(atPath: from, toPath: to)
    }
    static func delete(_ path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }
}
