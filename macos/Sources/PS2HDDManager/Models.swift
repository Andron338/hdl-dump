import Foundation

/// A whole physical external disk as reported by `diskutil`.
struct Drive: Identifiable, Hashable {
    var id: String { identifier }
    let identifier: String      // e.g. "disk4"
    let mediaName: String       // e.g. "WD Elements 25A2"
    let busProtocol: String     // e.g. "USB"
    let sizeBytes: UInt64
    let content: String         // partition scheme as macOS sees it
    let volumeNames: [String]   // mounted macOS volumes on this disk, if any

    /// Raw (unbuffered) device node: much faster for sequential writes.
    var rawDevicePath: String { "/dev/r\(identifier)" }
    var devicePath: String { "/dev/\(identifier)" }

    var displayName: String { mediaName.isEmpty ? identifier : mediaName }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .decimal) }
}

/// What we know about the PS2 layout of a drive.
enum DriveState: Equatable {
    case unknown                 // not read yet (reading needs admin rights)
    case loading
    case notPS2                  // readable, but no APA partition table
    case macVolumes([String])    // has volumes macOS mounted (exFAT, FAT32, ...), so it is not an APA drive
    case ps2(PS2Contents)
    case error(String)
}

struct PS2Contents: Equatable {
    var games: [Game]
    var totalMB: UInt64
    var usedMB: UInt64
    var freeMB: UInt64
}

struct Game: Identifiable, Hashable {
    var id: String { partition }
    let isDVD: Bool
    let sizeKB: UInt64
    let compatFlags: UInt32
    let dma: String
    let startup: String
    let partition: String
    let name: String

    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(sizeKB) * 1024, countStyle: .file) }
    var mediaText: String { isDVD ? "DVD" : "CD" }
    /// Game IDs identify a disc; names are free text and get truncated in partition names.
    var gameID: String { normalizedGameID(startup) }

    /// The original HD Loader only lists partitions named "PP.HDL.<name>".
    var isHDLoaderNamed: Bool { partition.hasPrefix("PP.HDL.") }
}

/// An image the user queued for installation.
struct InstallItem: Identifiable, Hashable {
    enum Status: Hashable {
        case pending
        case installing(Double, String) // fraction, "2 min left · 31 MB/s"
        case done
        case failed(String)
        case cancelled
        case duplicate(String)  // same game ID already on the drive or queued; skipped unless allowed
    }

    let id = UUID()
    let source: URL
    var name: String
    var startup: String
    var isDVD: Bool
    var sizeKB: UInt64
    var status: Status = .pending
    /// The user chose "Install Anyway" for a duplicate game ID.
    var allowDuplicate = false

    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(sizeKB) * 1024, countStyle: .file) }
}

/// "slus_200.62 " → "SLUS_200.62"; empty when unknown.
func normalizedGameID(_ s: String) -> String {
    let id = s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return id == "SLUS_000.00" ? "" : id
}

extension InstallItem {
    var gameID: String { normalizedGameID(startup) }
}

struct ToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
