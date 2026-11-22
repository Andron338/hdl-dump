import Foundation

/// Unprivileged process helpers (diskutil, reading ISO headers, ...).
enum Shell {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: Data
        var out: String { String(decoding: stdout, as: UTF8.self) }
        var err: String { String(decoding: stderr, as: UTF8.self) }
    }

    static func run(_ executable: String, _ args: [String]) async throws -> Result {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = args
            let o = Pipe(), e = Pipe()
            p.standardOutput = o
            p.standardError = e
            p.standardInput = FileHandle.nullDevice
            // Read pipes concurrently so a chatty process cannot fill the pipe buffer and hang.
            let outBox = DataBox(), errBox = DataBox()
            let group = DispatchGroup()
            group.enter(); group.enter()
            DispatchQueue.global().async { outBox.data = o.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            DispatchQueue.global().async { errBox.data = e.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            p.terminationHandler = { proc in
                group.notify(queue: .global()) {
                    cont.resume(returning: Result(status: proc.terminationStatus, stdout: outBox.data, stderr: errBox.data))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// POSIX single-quote escaping for /bin/sh.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Each box is written by exactly one reader before the DispatchGroup completes.
private final class DataBox: @unchecked Sendable { var data = Data() }

/// Strips ANSI escape sequences hdl_dump uses for bold/underline.
func stripANSI(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
}
