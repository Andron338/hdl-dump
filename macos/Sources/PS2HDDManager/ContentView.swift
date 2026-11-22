import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $store.selectedDriveID) {
                Section("External Drives") {
                    ForEach(store.drives) { drive in
                        DriveRow(drive: drive, state: store.state(of: drive))
                            .tag(drive.id)
                    }
                }
            }
            .overlay {
                if !store.hasScannedDrives {
                    ProgressView()
                } else if store.drives.isEmpty {
                    ContentUnavailableView("No External Drives",
                                           systemImage: "externaldrive.badge.questionmark",
                                           description: Text("Connect the PS2 hard drive with a USB or SATA adapter."))
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    AppIconArt(size: 22)
                    Text("PS2 HDD Manager").font(.caption.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 260)
        } detail: {
            if let drive = store.selectedDrive {
                DriveDetailView(drive: drive)
                    .id(drive.id)
            } else {
                WelcomeView()
            }
        }
        .tint(Theme.accent)
        .alert(item: $store.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message))
        }
    }
}

private struct DriveRow: View {
    let drive: Drive
    let state: DriveState

    private var contents: PS2Contents? { if case .ps2(let c) = state { return c }; return nil }

    var body: some View {
        HStack(spacing: 10) {
            DriveTile(systemImage: icon, isPS2: contents != nil, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(drive.displayName).font(.body.weight(.medium)).lineLimit(1)
                if let c = contents {
                    CapacityBar(totalMB: c.totalMB, gamesMB: c.gamesMB, systemMB: c.systemMB, height: 4)
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        if contents != nil { return "gamecontroller.fill" }
        return drive.busProtocol == "File" ? "doc.zipper" : "externaldrive.fill"
    }

    private var subtitle: String {
        if let c = contents {
            return "\(c.games.count) game\(c.games.count == 1 ? "" : "s") · \(Theme.mb(c.freeMB)) free"
        }
        var parts = [drive.sizeText]
        if !drive.busProtocol.isEmpty { parts.append(drive.busProtocol) }
        switch state {
        case .notPS2, .macVolumes: parts.append("not PS2")
        default: break
        }
        return parts.joined(separator: " · ")
    }
}

private struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 26) {
            AppIconArt(size: 128)
                .shadow(color: Theme.accent.opacity(0.35), radius: 24, y: 10)
            VStack(spacing: 6) {
                Text("PS2 HDD Manager").font(.largeTitle.weight(.bold))
                Text("Install PlayStation 2 games onto an internal PS2 hard drive.")
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 14) {
                Step(number: 1, symbol: "cable.connector", title: "Connect",
                     text: "Plug the drive in with a USB-SATA/IDE adapter and pick it on the left.")
                Step(number: 2, symbol: "wand.and.stars", title: "Format",
                     text: "New or Mac/PC drives need a one-time PS2 format.")
                Step(number: 3, symbol: "opticaldisc.fill", title: "Install",
                     text: "Drop ISOs in. OPL and HD Loader will see them.")
            }
            .frame(maxWidth: 640)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RadialGradient(colors: [Theme.accent.opacity(0.14), .clear], center: .top, startRadius: 0, endRadius: 520)
        )
    }

    private struct Step: View {
        let number: Int
        let symbol: String
        let title: String
        let text: String

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol).font(.title2).foregroundStyle(Theme.accent)
                    Spacer()
                    Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(Theme.accent, in: Circle())
                }
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(.background.secondary, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.5)))
        }
    }
}
