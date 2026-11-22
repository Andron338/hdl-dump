import Foundation
import Observation

@MainActor
@Observable
final class AppStore {
    var drives: [Drive] = []
    var hasScannedDrives = false
    var selectedDriveID: Drive.ID?
    var states: [Drive.ID: DriveState] = [:]

    var queue: [InstallItem] = []
    var isInstalling = false
    private var currentJob: UUID?
    private var cancelRequested = false

    var busyMessage: String?
    /// 0...1 while a multi-step operation (e.g. deleting several games) runs; nil = indeterminate.
    var busyProgress: Double?

    /// Name new installs "PP.HDL.<name>" so the original HD Loader sees them (OPL and HDD-OSD do too).
    var hdLoaderNames: Bool = UserDefaults.standard.object(forKey: "hdLoaderNames") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hdLoaderNames, forKey: "hdLoaderNames") }
    }
    var alert: AlertInfo?

    struct AlertInfo: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var selectedDrive: Drive? { drives.first { $0.id == selectedDriveID } }

    func state(of drive: Drive) -> DriveState { states[drive.id] ?? .unknown }

    // MARK: Drives

    func refreshDrives() async {
        var found = (try? await DiskService.externalDrives()) ?? []
        defer { hasScannedDrives = true }
        if let test = Tools.testDrive() { found.insert(test, at: 0) }
        if found != drives {
            let removed = Set(drives.map(\.id)).subtracting(found.map(\.id))
            for id in removed { states[id] = nil }
            for d in found where drives.first(where: { $0.id == d.id })?.volumeNames != d.volumeNames {
                states[d.id] = d.volumeNames.isEmpty ? nil : .macVolumes(d.volumeNames)
            }
            drives = found
            if let sel = selectedDriveID, !found.contains(where: { $0.id == sel }) { selectedDriveID = nil }
        }
        // Developer mode: open straight onto the test image.
        if selectedDriveID == nil, Tools.testImagePath != nil { selectedDriveID = Tools.testDriveID }
    }

    func watchDrives() async {
        while !Task.isCancelled {
            await refreshDrives()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func loadContents(_ staleDrive: Drive) async {
        // Callers may hold a copy captured before an operation (e.g. a format that removed the
        // drive's macOS volumes); always use what diskutil reports now.
        if !staleDrive.volumeNames.isEmpty { await refreshDrives() }
        let drive = drives.first { $0.id == staleDrive.id } ?? staleDrive
        // A PS2 (APA) drive is never mountable by macOS. If macOS mounted volumes from it, it is
        // something else — skip the raw read (no password prompt, and the file system holds the
        // device busy anyway).
        if !drive.volumeNames.isEmpty {
            states[drive.id] = .macVolumes(drive.volumeNames)
            return
        }
        // Keep showing the current game list while refreshing after an operation.
        if case .ps2 = states[drive.id] {} else { states[drive.id] = .loading }
        do {
            states[drive.id] = try await Tools.readContents(of: drive)
        } catch is CancellationError {
            states[drive.id] = .unknown
        } catch {
            states[drive.id] = .error(error.localizedDescription)
        }
    }

    // MARK: Queue

    func addImages(_ urls: [URL]) async {
        var problems: [String] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard Tools.supportedExtensions.contains(ext) else {
                problems.append("\(url.lastPathComponent): unsupported file type"); continue
            }
            if queue.contains(where: { $0.source == url }) { continue }
            do {
                var item = try await Tools.probeImage(url)
                if let reason = duplicateReason(for: item) { item.status = .duplicate(reason) }
                queue.append(item)
            } catch {
                problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !problems.isEmpty {
            alert = AlertInfo(title: "Some files were skipped", message: problems.joined(separator: "\n"))
        }
    }

    // MARK: Duplicates (by game ID, not name)

    private var selectedGames: [Game] {
        if let id = selectedDriveID, case .ps2(let c)? = states[id] { return c.games }
        return []
    }

    /// Why `item` would duplicate a game, or nil. Compares game IDs (e.g. SLUS_200.62):
    /// names differ between dumps, while the ID identifies the disc. Multi-disc games have
    /// a different ID per disc, so they are not flagged.
    func duplicateReason(for item: InstallItem, ignoringQueue: Bool = false) -> String? {
        let id = item.gameID
        guard !id.isEmpty, !item.allowDuplicate else { return nil }
        if let g = selectedGames.first(where: { $0.gameID == id }) { return "Already on drive as “\(g.name)”" }
        if !ignoringQueue, queue.contains(where: { $0.id != item.id && $0.gameID == id && $0.status != .cancelled }) {
            return "Already in queue"
        }
        return nil
    }

    func installAnyway(_ id: InstallItem.ID) {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[i].allowDuplicate = true
        queue[i].status = .pending
    }

    func removeFromQueue(_ ids: Set<InstallItem.ID>) {
        queue.removeAll { ids.contains($0.id) && !isActive($0) }
    }

    func clearFinished() {
        queue.removeAll { if case .done = $0.status { return true }; return false }
    }

    private func isActive(_ item: InstallItem) -> Bool {
        if case .installing = item.status { return true }; return false
    }

    var pendingCount: Int { queue.filter { $0.status == .pending }.count }

    func installQueue(on drive: Drive) async {
        // Only one disk write at a time: two processes rewriting the APA table would corrupt it.
        guard !isBusy else { return }
        isInstalling = true
        cancelRequested = false
        defer { isInstalling = false; currentJob = nil }

        // Retry failed / cancelled items too when the user presses Install again.
        for i in queue.indices {
            switch queue[i].status {
            case .failed, .cancelled: queue[i].status = .pending
            default: break
            }
        }

        while let index = queue.firstIndex(where: { $0.status == .pending }) {
            if cancelRequested { break }
            let item = queue[index]
            // The drive may have changed since the item was queued (another install, another tool).
            if let reason = duplicateReason(for: item, ignoringQueue: true) {
                queue[index].status = .duplicate(reason)
                continue
            }
            let job = UUID()
            currentJob = job
            queue[index].status = .installing(0, "")
            do {
                try await Tools.install(item, on: drive, jobID: job, hdLoaderNames: hdLoaderNames) { [weak self] p, detail in
                    guard let self, let i = self.queue.firstIndex(where: { $0.id == item.id }) else { return }
                    self.queue[i].status = .installing(p, detail)
                }
                setStatus(item.id, .done)
            } catch is CancellationError {
                setStatus(item.id, .cancelled)
                break
            } catch {
                setStatus(item.id, .failed(error.localizedDescription))
            }
        }
        await loadContents(drive)
    }

    func cancelInstall() {
        cancelRequested = true
        if let currentJob { PrivilegedRunner.shared.cancel(jobID: currentJob) }
    }

    private func setStatus(_ id: InstallItem.ID, _ s: InstallItem.Status) {
        if let i = queue.firstIndex(where: { $0.id == id }) { queue[i].status = s }
    }

    // MARK: Drive operations

    func delete(_ games: [Game], on drive: Drive) async {
        guard !games.isEmpty else { return }
        await perform("Deleting…", drive) {
            for (i, g) in games.enumerated() {
                busyMessage = games.count == 1 ? "Deleting “\(g.name)”…" : "Deleting \(i + 1) of \(games.count): “\(g.name)”…"
                busyProgress = Double(i) / Double(games.count)
                try await Tools.delete(g, on: drive)
            }
            busyProgress = 1
        }
        // Trust the drive, not the tool's exit status: confirm the partitions are really gone.
        if case .ps2(let c) = state(of: drive) {
            let left = games.filter { g in c.games.contains { $0.partition == g.partition } }
            if !left.isEmpty, alert == nil {
                alert = AlertInfo(title: "Some games were not deleted",
                                  message: left.map(\.name).joined(separator: "\n"))
            }
        }
    }

    func makeHDLoaderCompatible(_ games: [Game], on drive: Drive) async {
        let todo = games.filter { !$0.isHDLoaderNamed }
        guard !todo.isEmpty else { return }
        await perform("Updating \(todo.count) game\(todo.count == 1 ? "" : "s") for HD Loader…", drive) {
            for (i, g) in todo.enumerated() {
                busyMessage = "Updating \(i + 1) of \(todo.count) for HD Loader: “\(g.name)”…"
                busyProgress = Double(i) / Double(todo.count)
                try await Tools.makeHDLoaderCompatible(g, on: drive)
            }
        }
    }

    func rename(_ game: Game, to name: String, on drive: Drive) async {
        let clean = String(name.trimmingCharacters(in: .whitespaces).prefix(64))
        guard !clean.isEmpty, clean != game.name else { return }
        await perform("Renaming…", drive) { try await Tools.rename(game, to: clean, on: drive) }
    }

    func format(_ drive: Drive, createOPLPartition: Bool) async {
        await perform("Formatting \(drive.displayName)…", drive) {
            try await Tools.format(drive, createOPLPartition: createOPLPartition)
        }
    }

    /// True while any operation that writes to a drive is running.
    var isBusy: Bool { isInstalling || busyMessage != nil }

    private func perform(_ message: String, _ drive: Drive, _ op: () async throws -> Void) async {
        guard !isBusy else { return }
        busyMessage = message
        busyProgress = nil
        defer { busyMessage = nil; busyProgress = nil }
        do {
            try await op()
        } catch is CancellationError {
            return
        } catch {
            alert = AlertInfo(title: "Operation failed", message: error.localizedDescription)
        }
        await loadContents(drive)
    }
}
