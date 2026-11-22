import Foundation

/// Enumerates external physical disks via `diskutil`. Internal disks are never returned,
/// so the app cannot be pointed at the Mac's own drive.
enum DiskService {
    static func externalDrives() async throws -> [Drive] {
        let list = try await Shell.run("/usr/sbin/diskutil", ["list", "-plist", "external", "physical"])
        guard list.status == 0,
              let plist = try PropertyListSerialization.propertyList(from: list.stdout, format: nil) as? [String: Any],
              let whole = plist["WholeDisks"] as? [String]
        else { return [] }

        let all = plist["AllDisksAndPartitions"] as? [[String: Any]] ?? []
        var drives: [Drive] = []
        for ident in whole {
            guard let info = try await info(ident) else { continue }
            // Belt and braces: skip anything macOS says is internal, virtual or the boot disk.
            if (info["Internal"] as? Bool) == true { continue }
            if (info["VirtualOrPhysical"] as? String) == "Virtual" { continue }
            if ident == (try? await bootDiskIdentifier()) { continue }

            let entry = all.first { ($0["DeviceIdentifier"] as? String) == ident }
            let parts = entry?["Partitions"] as? [[String: Any]] ?? []
            let volumes = parts.compactMap { $0["MountPoint"] as? String }.map { ($0 as NSString).lastPathComponent }

            drives.append(Drive(
                identifier: ident,
                mediaName: (info["MediaName"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                busProtocol: info["BusProtocol"] as? String ?? "",
                sizeBytes: (info["TotalSize"] as? NSNumber)?.uint64Value ?? (info["Size"] as? NSNumber)?.uint64Value ?? 0,
                content: info["Content"] as? String ?? "",
                volumeNames: volumes
            ))
        }
        return drives
    }

    private static func info(_ ident: String) async throws -> [String: Any]? {
        let r = try await Shell.run("/usr/sbin/diskutil", ["info", "-plist", ident])
        guard r.status == 0 else { return nil }
        return try PropertyListSerialization.propertyList(from: r.stdout, format: nil) as? [String: Any]
    }

    private static var cachedBootDisk: String?
    private static func bootDiskIdentifier() async throws -> String? {
        if let cachedBootDisk { return cachedBootDisk }
        guard let i = try await info("/") else { return nil }
        let parent = i["ParentWholeDisk"] as? String
        cachedBootDisk = parent
        return parent
    }

    /// PS2 (APA) disks are never mounted by macOS, but a drive being reformatted might be.
    static func unmount(_ drive: Drive) async {
        _ = try? await Shell.run("/usr/sbin/diskutil", ["unmountDisk", drive.devicePath])
    }
}
