import AppKit
import Foundation
import Security

/// Runs commands as root. Raw disk devices (/dev/rdiskN) are root-only on macOS.
///
/// On first use the user authorizes once (standard macOS password / Touch ID prompt). We then start
/// a root `/bin/sh` via AuthorizationExecuteWithPrivileges whose stdin is a private socket held only by
/// this process, and feed every later command through it — one prompt per app launch, and no other
/// process can talk to the root shell. The shell exits when the app quits (EOF on its stdin).
///
/// Each command runs in the background writing to a log file (tailed for live progress) plus an exit
/// status file and a pid file (for cancellation).
@MainActor
final class PrivilegedRunner {
    static let shared = PrivilegedRunner()

    private let workDir: URL
    private var running: [UUID: Int32] = [:] // job id -> pid of the wrapping subshell
    private var helper: FileHandle?           // write end to the root shell's stdin

    private init() {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("PS2HDDManager-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        signal(SIGPIPE, SIG_IGN) // a dead helper must surface as a write error, not kill the app
    }

    struct Output {
        let status: Int32
        let text: String
    }

    /// - Parameters:
    ///   - argv: executable + arguments, each quoted individually.
    ///   - stdin: optional text piped to the command (used for pfsshell scripts).
    ///   - onOutput: called on the main actor with the full output so far (hdl_dump uses `\r` for progress).
    func run(_ argv: [String], stdin: String? = nil, jobID: UUID = UUID(),
             onOutput: ((String) -> Void)? = nil) async throws -> Output {
        let log = workDir.appendingPathComponent("\(jobID).log")
        let exitFile = workDir.appendingPathComponent("\(jobID).exit")
        let pidFile = workDir.appendingPathComponent("\(jobID).pid")
        let inFile = workDir.appendingPathComponent("\(jobID).in")
        var stdinRedirect = "< /dev/null"
        if let stdin {
            try stdin.write(to: inFile, atomically: true, encoding: .utf8)
            stdinRedirect = "< \(Shell.quote(inFile.path))"
        }
        defer {
            for f in [log, exitFile, pidFile, inFile] { try? FileManager.default.removeItem(at: f) }
        }

        // Newlines would split the command for the line-reading root shell; no legitimate argument has one.
        let cmd = argv.map { Shell.quote($0.replacingOccurrences(of: "\n", with: " ")) }.joined(separator: " ")
        let script = "( \(cmd) \(stdinRedirect) > \(Shell.quote(log.path)) 2>&1; echo $? > \(Shell.quote(exitFile.path)) ) "
            + "> /dev/null 2>&1 & echo $! > \(Shell.quote(pidFile.path))"
        try await send(script)
        defer { running[jobID] = nil }

        var lastLength = -1
        while true {
            if running[jobID] == nil, let t = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = Int32(t.trimmingCharacters(in: .whitespacesAndNewlines)) {
                running[jobID] = pid
            }
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            if text.utf8.count != lastLength {
                lastLength = text.utf8.count
                onOutput?(text)
            }
            if let ex = try? String(contentsOf: exitFile, encoding: .utf8),
               let status = Int32(ex.trimmingCharacters(in: .whitespacesAndNewlines)) {
                let final = (try? String(contentsOf: log, encoding: .utf8)) ?? text
                onOutput?(final)
                return Output(status: status, text: stripANSI(final))
            }
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    /// Sends SIGINT to the running command; hdl_dump catches it and cleans up the partial install.
    func cancel(jobID: UUID) {
        guard let pid = running[jobID] else { return }
        Task { try? await send("/usr/bin/pkill -INT -P \(pid)") }
    }

    // MARK: Root shell

    private func send(_ line: String) async throws {
        let data = Data((line + "\n").utf8)
        if let helper {
            do { try helper.write(contentsOf: data); return } catch { self.helper = nil } // helper died; restart
        }
        let h = try await startHelper()
        try h.write(contentsOf: data)
    }

    private typealias AEWP = @convention(c) (
        AuthorizationRef, UnsafePointer<CChar>, AuthorizationFlags,
        UnsafePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    private func startHelper() async throws -> FileHandle {
        // Deprecated but still shipped API; it is the only way to get a root process with a private pipe
        // without installing a launchd helper. Resolved at runtime because Swift marks it unavailable.
        guard let lib = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let sym = dlsym(lib, "AuthorizationExecuteWithPrivileges")
        else { throw ToolError(message: "macOS no longer provides the authorization API this app needs.") }
        let aewp = unsafeBitCast(sym, to: AEWP.self)

        var authRef: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authRef) == errAuthorizationSuccess, let authRef else {
            throw ToolError(message: "Could not create an authorization session.")
        }
        defer { AuthorizationFree(authRef, []) }

        let status: OSStatus = kAuthorizationRightExecute.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPtr in
                var rights = AuthorizationRights(count: 1, items: itemPtr)
                return AuthorizationCopyRights(authRef, &rights, nil, [.interactionAllowed, .extendRights, .preAuthorize], nil)
            }
        }
        if status == errAuthorizationCanceled { throw CancellationError() }
        guard status == errAuthorizationSuccess else {
            throw ToolError(message: "Administrator authorization failed (\(status)).")
        }

        var pipe: UnsafeMutablePointer<FILE>?
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("-s"), nil]
        defer { argv.forEach { free($0) } }
        let rc = argv.withUnsafeBufferPointer { buf in
            aewp(authRef, "/bin/sh", [], buf.baseAddress!, &pipe)
        }
        guard rc == errAuthorizationSuccess, let pipe else {
            throw ToolError(message: "Could not start the privileged helper (\(rc)).")
        }

        // The pipe is a socket wired to the shell's stdin and stdout. Duplicate the descriptor so it
        // outlives the FILE*, and drain anything the shell prints so it can never block.
        let fd = dup(fileno(pipe))
        fclose(pipe)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        handle.readabilityHandler = { h in
            if h.availableData.isEmpty { h.readabilityHandler = nil }
        }
        helper = handle
        return handle
    }
}
