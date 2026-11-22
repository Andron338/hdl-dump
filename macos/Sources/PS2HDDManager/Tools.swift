import Foundation

/// Wrappers around the bundled `hdl_dump` (game install/list/rename) and
/// `pfsshell` (APA format, partition removal) command-line engines.
@MainActor
enum Tools {
    // MARK: Binaries

    static func binary(_ name: String) throws -> String {
        let candidates: [URL?] = [
            Bundle.main.url(forAuxiliaryExecutable: name),
            Bundle.main.resourceURL?.appendingPathComponent("bin/\(name)"),
            ProcessInfo.processInfo.environment["PS2HDD_BIN_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent(name) },
        ]
        for case let url? in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return url.path
        }
        throw ToolError(message: "The bundled \(name) tool is missing. Rebuild the app with build_app.sh.")
    }

    // MARK: Target paths

    /// Developer mode: a disk image file stands in for a drive and no admin rights are used.
    static var testImagePath: String? { ProcessInfo.processInfo.environment["PS2HDD_TEST_IMAGE"] }

    static func target(for drive: Drive) -> String {
        drive.identifier == testDriveID ? (testImagePath ?? "") : drive.rawDevicePath
    }

    static let testDriveID = "test-image"

    static func testDrive() -> Drive? {
        guard let path = testImagePath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return Drive(identifier: testDriveID, mediaName: "Test image (\((path as NSString).lastPathComponent))",
                     busProtocol: "File", sizeBytes: size.uint64Value, content: "", volumeNames: [])
    }

    /// Routes through admin authorization for real devices; runs directly for the test image.
    /// `writes`: the command modifies the disk, so any macOS volumes on it are unmounted first.
    /// Read-only commands never unmount anything.
    private static func exec(_ drive: Drive, _ argv: [String], stdin: String? = nil, jobID: UUID = UUID(),
                             writes: Bool, onOutput: ((String) -> Void)? = nil) async throws -> PrivilegedRunner.Output {
        if drive.identifier == testDriveID {
            return try await runUnprivileged(argv, stdin: stdin, onOutput: onOutput)
        }
        if writes { await DiskService.unmount(drive) }
        return try await PrivilegedRunner.shared.run(argv, stdin: stdin, jobID: jobID, onOutput: onOutput)
    }

    // MARK: Listing

    static func readContents(of drive: Drive) async throws -> DriveState {
        let out = try await exec(drive, [try binary("hdl_dump"), "hdl_toc", target(for: drive), "--tsv"], writes: false)
        if out.status == 101 || out.status == 107 { return .notPS2 }
        if out.text.contains("Operation not permitted") { return .error(diskAccessDenied) }
        if out.text.contains("Resource busy") { return .error(diskBusy) }
        guard out.status == 0 else { return .error(describe(out)) }

        var games: [Game] = []
        var total: UInt64 = 0, used: UInt64 = 0, free: UInt64 = 0
        for line in out.text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if f.first == "#total", f.count >= 4 {
                total = UInt64(f[1]) ?? 0; used = UInt64(f[2]) ?? 0; free = UInt64(f[3]) ?? 0
            } else if f.count >= 7 {
                games.append(Game(isDVD: f[0] == "DVD", sizeKB: UInt64(f[1]) ?? 0, compatFlags: UInt32(f[2]) ?? 0,
                                  dma: f[3], startup: f[4].trimmingCharacters(in: .whitespaces), partition: f[5],
                                  name: f[6...].joined(separator: "\t")))
            }
        }
        games.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return .ps2(PS2Contents(games: games, totalMB: total, usedMB: used, freeMB: free))
    }

    // MARK: Images

    static let supportedExtensions = ["iso", "cue", "nrg", "gi", "iml", "zso"]

    /// Reads volume label, startup ELF, media type and size from an image (no admin rights needed).
    static func probeImage(_ url: URL) async throws -> InstallItem {
        let r = try await Shell.run(try binary("hdl_dump"), ["cdvd_info2", url.path, "--csv"])
        let line = stripANSI(r.out).split(separator: "\n").last.map(String.init) ?? ""
        let f = line.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard r.status == 0, f.count >= 4 else {
            let msg = stripANSI(r.out + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ToolError(message: msg.isEmpty ? "Not a PlayStation 2 disc image." :
                                msg.replacingOccurrences(of: url.path + ": ", with: ""))
        }
        let media = f[0]
        let sizeKB = UInt64(f[1].replacingOccurrences(of: "KB", with: "")) ?? 0
        let volume = f[2].trimmingCharacters(in: .whitespaces)
        let startup = f[3...].joined(separator: ";").trimmingCharacters(in: .whitespaces)
        // hdl_dump reports plain ISO files as DVD; anything that fits on a CD is installed as CD
        // unless it is dual layer.
        let isDVD = media.contains("dual-layer") || (media.hasSuffix("DVD") && sizeKB > 700 * 1024)
        let baseName = url.deletingPathExtension().lastPathComponent
        let name = cleanGameName(baseName.isEmpty ? volume : baseName)
        return InstallItem(source: url, name: name, startup: startup, isDVD: isDVD, sizeKB: sizeKB)
    }

    /// Strips common dump tags like "(USA)" / "[SLUS-12345]" and clamps to the HDL 64-byte limit.
    static func cleanGameName(_ s: String) -> String {
        var n = s.replacingOccurrences(of: "\\s*[\\[(][^\\])]*[\\])]", with: "", options: .regularExpression)
        n = n.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        if n.isEmpty { n = s }
        while n.utf8.count > 64 { n.removeLast() }
        return n
    }

    // MARK: Writes

    static func install(_ item: InstallItem, on drive: Drive, jobID: UUID, hdLoaderNames: Bool,
                        progress: @escaping (Double, String) -> Void) async throws {
        var argv = [try binary("hdl_dump"), item.isDVD ? "inject_dvd" : "inject_cd",
                    target(for: drive), item.name, item.source.path, item.startup, "*u4"]
        if hdLoaderNames { argv.append("-hdl") }
        let out = try await exec(drive, argv, jobID: jobID, writes: true) { text in
            if let p = parseProgress(text) { progress(p.fraction, p.detail) }
        }
        if out.status == 109 { throw CancellationError() }
        if out.text.contains("Operation not permitted") { throw ToolError(message: diskAccessDenied) }
        if out.text.contains("Resource busy") { throw ToolError(message: diskBusy) }
        guard out.status == 0 else { throw ToolError(message: describe(out)) }
    }

    static func rename(_ game: Game, to newName: String, on drive: Drive) async throws {
        let out = try await exec(drive, [try binary("hdl_dump"), "modify", target(for: drive), game.partition, newName], writes: true)
        guard out.status == 0 else { throw ToolError(message: describe(out)) }
    }

    /// Renames partitions to "PP.HDL.<name>" so the original HD Loader lists them.
    static func makeHDLoaderCompatible(_ game: Game, on drive: Drive) async throws {
        let out = try await exec(drive, [try binary("hdl_dump"), "modify", target(for: drive), game.partition, "-hdl"], writes: true)
        guard out.status == 0 else { throw ToolError(message: "\(game.name): \(describe(out))") }
    }

    /// Removes one game's partition (pfsshell `rmpart` frees the space; `hdl_dump delete` only hides it).
    static func delete(_ game: Game, on drive: Drive) async throws {
        let script = "device \(try pfsQuote(target(for: drive)))\nrmpart \(try pfsQuote(game.partition))\nexit\n"
        let out = try await exec(drive, [try binary("pfsshell")], stdin: script, writes: true)
        if let err = pfsshellError(out.text) { throw ToolError(message: "\(game.name): \(err)") }
    }

    /// Creates a fresh APA layout (__mbr, __net, __system, __sysconf, __common), optionally with
    /// a +OPL partition for Open PS2 Loader settings.
    static func format(_ drive: Drive, createOPLPartition: Bool) async throws {
        var script = "device \(try pfsQuote(target(for: drive)))\ninitialize yes\n"
        if createOPLPartition { script += "mkpart +OPL 128M PFS\n" }
        script += "exit\n"
        let out = try await exec(drive, [try binary("pfsshell")], stdin: script, writes: true)
        if let err = pfsshellError(out.text) { throw ToolError(message: err) }
    }

    /// pfsshell splits its command line on spaces (HD Loader names like "PP.HDL.Grand Theft Auto" have
    /// them) but honours "double" or 'single' quotes around a whole argument.
    static func pfsQuote(_ s: String) throws -> String {
        if !s.contains("\"") { return "\"\(s)\"" }
        if !s.contains("'") { return "'\(s)'" }
        throw ToolError(message: "Can't pass “\(s)” to pfsshell (it contains both kinds of quotes).")
    }

    /// pfsshell reports failures as "(!) …" and does not set an exit status. The message can follow
    /// its prompt on the same line ("> # (!) rmpart: …"), so search anywhere in the line.
    static func pfsshellError(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            if let r = line.range(of: "(!)") {
                return line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static let diskAccessDenied = "macOS blocked raw access to this disk. Turn on PS2 HDD Manager in System Settings › Privacy & Security › Full Disk Access, then try again."

    static let diskBusy = "Another app or macOS is using this disk. Eject it in Finder or Disk Utility without unplugging, then try again."

    // MARK: Output parsing

    /// hdl_dump rewrites one progress line with "\r", e.g.
    /// `[====>   ]  45%, 2 min, 10 sec remaining, 31.20 MB/sec`. Parse the last complete one.
    /// (A backwards regex search would match only "5%" of "45%", so split into lines first.)
    static func parseProgress(_ text: String) -> (fraction: Double, detail: String)? {
        let lines = text.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
        guard let line = lines.last(where: { $0.contains("%") }).map(String.init),
              let pc = firstCapture(#"(\d{1,3})%"#, in: line).flatMap(Double.init) else { return nil }
        var parts: [String] = []
        if let left = firstCapture(#"%,\s*(.+?) remaining"#, in: line) { parts.append("\(left) left") }
        if let speed = firstCapture(#"([\d.]+) MB/sec"#, in: line).flatMap(Double.init), speed > 0 {
            parts.append("\(Int(speed.rounded())) MB/s")
        }
        return (min(pc, 100) / 100, parts.joined(separator: " · "))
    }

    private static func firstCapture(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private static func describe(_ out: PrivilegedRunner.Output) -> String {
        let lines = out.text.replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") && !$0.hasSuffix("%") }
        return lines.last ?? "The tool exited with code \(out.status)."
    }

    // MARK: Unprivileged path (test image)

    private static func runUnprivileged(_ argv: [String], stdin: String?,
                                        onOutput: ((String) -> Void)?) async throws -> PrivilegedRunner.Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let input = Pipe()
        p.standardInput = input
        let buffer = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let text = buffer.append(d)
            Task { @MainActor in onOutput?(text) }
        }
        try p.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? input.fileHandleForWriting.close()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { p.waitUntilExit(); c.resume() }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = buffer.append(rest)
        return PrivilegedRunner.Output(status: p.terminationStatus, text: stripANSI(text))
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) -> String {
        lock.lock(); defer { lock.unlock() }
        data.append(d)
        return String(decoding: data, as: UTF8.self)
    }
}
