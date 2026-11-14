import Darwin
import Foundation

/// Records both process start times so a reused PID is never mistaken for our tunnel.
enum TunnelOwnership {
    struct Identity: Codable, Equatable {
        let pid: Int32
        let seconds: UInt64
        let microseconds: UInt64
    }

    struct Record: Codable {
        let owner: Identity
        let tunnel: Identity
    }

    private static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(AppInfo.bundleID, isDirectory: true)
            .appendingPathComponent("tunnels", isDirectory: true)
    }

    static func identity(_ pid: Int32) -> Identity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == getuid() else { return nil }
        return Identity(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    static func record(pid: Int32) -> URL? {
        guard let directory, let owner = identity(getpid()), let tunnel = identity(pid),
              let data = try? JSONEncoder().encode(Record(owner: owner, tunnel: tunnel)) else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent(UUID().uuidString + ".json")
            try data.write(to: url, options: .atomic)
            return url
        } catch { return nil }
    }

    static func cleanOrphans() {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(Record.self, from: data) else { continue }
            if let currentOwner = identity(record.owner.pid) {
                if currentOwner == record.owner { continue }
            } else if kill(record.owner.pid, 0) == 0 || errno != ESRCH {
                continue
            }
            if identity(record.tunnel.pid) == record.tunnel {
                _ = kill(record.tunnel.pid, SIGTERM)
            } else {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
