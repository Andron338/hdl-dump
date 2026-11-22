import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DriveDetailView: View {
    @Environment(AppStore.self) private var store
    let drive: Drive

    @State private var selection = Set<Game.ID>()
    @State private var showImporter = false
    @State private var showFormat = false
    @State private var renaming: Game?
    @State private var confirmDelete: [Game] = []
    @State private var dropTargeted = false
    @State private var search = ""

    private var state: DriveState { store.state(of: drive) }
    private var contents: PS2Contents? { if case .ps2(let c) = state { return c }; return nil }

    var body: some View {
        VStack(spacing: 0) {
            DriveHeader(drive: drive, contents: contents, isLoading: state == .loading)
            Divider()
            if store.queue.isEmpty {
                main
            } else {
                // Draggable divider between the drive's games and the install queue.
                VSplitView {
                    main.frame(minHeight: 140, maxHeight: .infinity)
                    InstallQueueView(drive: drive, freeMB: contents?.freeMB)
                        .frame(minHeight: 170, idealHeight: 260, maxHeight: .infinity)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay { busyOverlay }
        .overlay { dropHighlight }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers); return true
        }
        .navigationTitle(drive.displayName)
        .navigationSubtitle(drive.identifier == Tools.testDriveID ? "Disk image" : drive.devicePath)
        .searchable(text: $search, placement: .toolbar, prompt: "Search games")
        .toolbar { toolbar }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: imageTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await store.addImages(urls) } }
        }
        .sheet(isPresented: $showFormat) { FormatSheet(drive: drive) }
        .sheet(item: $renaming) { game in RenameSheet(game: game, drive: drive) }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !confirmDelete.isEmpty }, set: { if !$0 { confirmDelete = [] } })) {
            Button("Delete", role: .destructive) {
                let games = confirmDelete
                selection.subtract(games.map(\.id))
                Task { await store.delete(games, on: drive) }
            }
        } message: {
            Text("The game partitions are removed from the drive and their space is freed. This cannot be undone.")
        }
        .task {
            if case .unknown = state, drive.identifier == Tools.testDriveID { await store.loadContents(drive) }
            // Developer mode only: pre-fill the queue (colon-separated paths) for UI testing.
            if drive.identifier == Tools.testDriveID, contents != nil, store.queue.isEmpty,
               let paths = ProcessInfo.processInfo.environment["PS2HDD_TEST_QUEUE"] {
                await store.addImages(paths.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
            }
        }
    }

    // MARK: Main area

    @ViewBuilder private var main: some View {
        switch state {
        case .unknown:
            StatePanel(symbol: "lock.open.fill", tint: Theme.accent, title: "Read This Drive",
                       message: "macOS only lets administrators read raw disks. You'll be asked for your password once per launch.") {
                Button { Task { await store.loadContents(drive) } } label: {
                    Label("Read Drive", systemImage: "arrow.down.circle.fill").padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(Theme.accent)
            }
        case .loading:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Reading partition table…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notPS2:
            StatePanel(symbol: "externaldrive.badge.xmark", tint: .orange, title: "Not a PS2 Drive",
                       message: "This drive has no PlayStation 2 (APA) partition table. Format it to use it with a PS2.") {
                Button("Format for PS2…", role: .destructive) { showFormat = true }.controlSize(.large)
            }
        case .macVolumes(let volumes):
            StatePanel(symbol: "externaldrive.badge.xmark", tint: .orange, title: "Not a PS2 Drive",
                       message: "macOS has this drive mounted as “\(volumes.joined(separator: "”, “"))”, so it uses a Mac/PC file system, not the PS2 HDD format. Formatting it for PS2 erases those files.") {
                Button("Format for PS2…", role: .destructive) { showFormat = true }.controlSize(.large)
            }
        case .error(let message):
            StatePanel(symbol: "exclamationmark.triangle.fill", tint: .red, title: "Couldn't Read Drive", message: message) {
                HStack {
                    if message == Tools.diskAccessDenied {
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                    }
                    Button("Try Again") { Task { await store.loadContents(drive) } }
                }
                .controlSize(.large)
            }
        case .ps2(let c):
            if c.games.isEmpty {
                DropZone(targeted: dropTargeted) { showImporter = true }
            } else {
                VStack(spacing: 0) {
                    let hidden = c.games.filter { !$0.isHDLoaderNamed }
                    if !hidden.isEmpty {
                        Banner(symbol: "eye.slash.fill", tint: .orange,
                               text: "\(hidden.count) game\(hidden.count == 1 ? " is" : "s are") not visible in the original HD Loader.") {
                            Button("Make Visible in HD Loader") {
                                Task { await store.makeHDLoaderCompatible(hidden, on: drive) }
                            }
                            .disabled(store.isBusy)
                        }
                    }
                    gamesList(c.games)
                }
            }
        }
    }

    private func gamesList(_ games: [Game]) -> some View {
        let duplicateIDs = Set(Dictionary(grouping: games.filter { !$0.gameID.isEmpty }, by: \.gameID)
            .filter { $0.value.count > 1 }.keys)
        let shown = search.isEmpty ? games : games.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.startup.localizedCaseInsensitiveContains(search)
        }
        return List(selection: $selection) {
            Section {
                ForEach(shown) { game in
                    GameRow(game: game, isDuplicate: duplicateIDs.contains(game.gameID))
                        .tag(game.id)
                }
            } header: {
                HStack {
                    Text(search.isEmpty ? "Games" : "\(shown.count) of \(games.count) games")
                    Spacer()
                    Text("Double-click to rename").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Game.ID.self) { ids in
            let picked = games.filter { ids.contains($0.id) }
            if picked.count == 1 {
                Button("Rename…") { renaming = picked[0] }
            }
            if picked.contains(where: { !$0.isHDLoaderNamed }) {
                Button("Make Visible in HD Loader") { Task { await store.makeHDLoaderCompatible(picked, on: drive) } }
            }
            if !picked.isEmpty {
                Divider()
                Button("Delete…", role: .destructive) { confirmDelete = picked }
            }
        } primaryAction: { ids in
            if ids.count == 1, let g = games.first(where: { ids.contains($0.id) }) { renaming = g }
        }
        .onDeleteCommand {
            confirmDelete = games.filter { selection.contains($0.id) }
        }
        .overlay {
            if shown.isEmpty { ContentUnavailableView.search(text: search) }
        }
    }

    // MARK: Overlays

    @ViewBuilder private var busyOverlay: some View {
        if let msg = store.busyMessage {
            ZStack {
                Color.black.opacity(0.12)
                VStack(spacing: 12) {
                    if let p = store.busyProgress {
                        ProgressView(value: p).progressViewStyle(.linear).tint(Theme.accent).frame(width: 260)
                            .animation(.easeOut, value: p)
                    } else {
                        ProgressView().controlSize(.large)
                    }
                    Text(msg).font(.callout.weight(.medium)).multilineTextAlignment(.center).frame(maxWidth: 320)
                }
                .padding(.horizontal, 28).padding(.vertical, 22)
                .background(.regularMaterial, in: .rect(cornerRadius: 16, style: .continuous))
                .shadow(radius: 20, y: 6)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder private var dropHighlight: some View {
        if dropTargeted && !(contents?.games.isEmpty ?? true) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                .background(Theme.accent.opacity(0.06), in: .rect(cornerRadius: 14))
                .padding(8)
                .allowsHitTesting(false)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showImporter = true } label: { Label("Add Games", systemImage: "plus") }
                .help("Add disc images to the install queue")
                .disabled(contents == nil)
            Button {
                confirmDelete = (contents?.games ?? []).filter { selection.contains($0.id) }
            } label: { Label("Delete", systemImage: "trash") }
                .help("Delete selected games")
                .disabled(selection.isEmpty || store.isBusy)
            Button { Task { await store.loadContents(drive) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Re-read the drive")
                .disabled(store.isInstalling || state == .loading)
            Menu {
                Button("Format for PS2…", role: .destructive) { showFormat = true }
            } label: { Label("More", systemImage: "ellipsis.circle") }
                .disabled(store.isBusy)
        }
    }

    private var deleteTitle: String {
        confirmDelete.count == 1 ? "Delete “\(confirmDelete[0].name)”?" : "Delete \(confirmDelete.count) games?"
    }

    private var imageTypes: [UTType] {
        Tools.supportedExtensions.compactMap { UTType(filenameExtension: $0) } + [.diskImage]
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        guard contents != nil else {
            store.alert = .init(title: "Drive not ready", message: "Read or format the drive before adding games.")
            return
        }
        Task {
            var urls: [URL] = []
            for p in providers {
                if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                   let u = URL(dataRepresentation: url, relativeTo: nil) {
                    urls.append(u)
                }
            }
            await store.addImages(urls)
        }
    }
}

// MARK: - Pieces

private struct GameRow: View {
    let game: Game
    let isDuplicate: Bool

    var body: some View {
        HStack(spacing: 12) {
            DiscIcon(isDVD: game.isDVD, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(game.name).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Pill(text: game.startup.isEmpty ? "No ID" : game.startup, mono: true)
                    Pill(text: game.mediaText, tint: game.isDVD ? Theme.accent : .orange)
                    if isDuplicate { Pill(text: "Duplicate", tint: .red) }
                    if !game.isHDLoaderNamed {
                        Image(systemName: "eye.slash").font(.caption).foregroundStyle(.orange)
                            .help("Not visible in the original HD Loader")
                    }
                }
            }
            Spacer(minLength: 12)
            Text(game.sizeText).font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .help(game.partition)
    }
}

private struct DriveHeader: View {
    let drive: Drive
    let contents: PS2Contents?
    let isLoading: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            DriveTile(systemImage: contents == nil ? "externaldrive.fill" : "gamecontroller.fill",
                      isPS2: contents != nil, size: 58)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(drive.displayName).font(.title2.weight(.bold))
                    if contents != nil { Pill(text: "PS2 APA", tint: Theme.accent) }
                }
                if let c = contents {
                    CapacityBar(totalMB: c.totalMB, gamesMB: c.gamesMB, systemMB: c.systemMB)
                        .frame(maxWidth: 520)
                    HStack(spacing: 14) {
                        LegendDot(color: AnyShapeStyle(Theme.accent), label: "Games \(Theme.mb(c.gamesMB))")
                        LegendDot(color: AnyShapeStyle(Theme.system), label: "System \(Theme.mb(c.systemMB))")
                        LegendDot(color: AnyShapeStyle(Color.secondary.opacity(0.2)), label: "Free \(Theme.mb(c.freeMB))")
                    }
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text([drive.sizeText, drive.busProtocol, drive.volumeNames.isEmpty ? nil : "Volumes: " + drive.volumeNames.joined(separator: ", ")]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let c = contents {
                HStack(spacing: 10) {
                    StatTile(value: "\(c.games.count)", label: c.games.count == 1 ? "Game" : "Games")
                    StatTile(value: Theme.mb(c.freeMB), label: "Free")
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .background(Theme.heroGradient)
    }
}

private struct StatTile: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 74)
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(.background.opacity(0.6), in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

struct StatePanel<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.12)).frame(width: 84, height: 84)
                Image(systemName: symbol).font(.system(size: 34, weight: .semibold)).foregroundStyle(tint)
            }
            Text(title).font(.title3.weight(.semibold))
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
            actions().padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Banner<Action: View>: View {
    let symbol: String
    let tint: Color
    let text: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
            Spacer()
            action()
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(tint.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct DropZone: View {
    let targeted: Bool
    let browse: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                DiscIcon(isDVD: false, size: 64).offset(x: -26, y: 6).rotationEffect(.degrees(-8))
                DiscIcon(isDVD: true, size: 76)
            }
            .scaleEffect(targeted ? 1.08 : 1)
            .animation(.spring(duration: 0.3), value: targeted)
            VStack(spacing: 6) {
                Text("Drop Disc Images Here").font(.title3.weight(.semibold))
                Text("ISO, CUE/BIN, NRG, IML, GI or ZSO — names and game IDs are read automatically.")
                    .foregroundStyle(.secondary)
            }
            Button("Choose Files…", action: browse)
                .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(targeted ? Theme.accent : Color.secondary.opacity(0.3),
                              style: StrokeStyle(lineWidth: 2, dash: [10, 7]))
                .background((targeted ? Theme.accent.opacity(0.07) : Color.clear), in: .rect(cornerRadius: 18))
                .padding(20)
        )
    }
}
