import SwiftUI

struct InstallQueueView: View {
    @Environment(AppStore.self) private var store
    let drive: Drive
    let freeMB: UInt64?

    private var installable: [InstallItem] { store.queue.filter(isInstallable) }

    private var pendingMB: UInt64 {
        // HDL allocates in 128 MB chunks; round each game up so the estimate is conservative.
        installable.reduce(0) { $0 + (($1.sizeKB / 1024 + 127) / 128 + 1) * 128 }
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(Theme.accent)
                Text("Install Queue").font(.headline)
                Pill(text: "\(store.queue.count)", tint: Theme.accent)
                if let freeMB, pendingMB > freeMB {
                    Label("Needs \(Theme.mb(pendingMB)), \(Theme.mb(freeMB)) free", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                }
                Spacer()
                Toggle("HD Loader names", isOn: $store.hdLoaderNames)
                    .toggleStyle(.checkbox)
                    .help("Name partitions PP.HDL.<name> so the original HD Loader lists the games. OPL and HDD-OSD see them either way.")
                    .disabled(store.isInstalling)
                if store.isInstalling {
                    Button(role: .cancel) { store.cancelInstall() } label: { Label("Stop", systemImage: "stop.fill") }
                } else {
                    Button("Clear Finished") { store.clearFinished() }
                        .disabled(!store.queue.contains { $0.status == .done })
                    Button {
                        Task { await store.installQueue(on: drive) }
                    } label: {
                        Label(installable.isEmpty ? "Install" : "Install \(installable.count) Game\(installable.count == 1 ? "" : "s")",
                              systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(installable.isEmpty || freeMB == nil || store.isBusy)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.bar)
            Divider()

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach($store.queue) { $item in
                        QueueRow(item: $item)
                    }
                }
                .padding(12)
            }
        }
    }

    private func isInstallable(_ item: InstallItem) -> Bool {
        switch item.status {
        case .pending, .failed, .cancelled: return true
        default: return false
        }
    }
}

private struct QueueRow: View {
    @Environment(AppStore.self) private var store
    @Binding var item: InstallItem
    @State private var hovering = false

    private var editable: Bool { item.status == .pending }
    private var isDuplicate: Bool { if case .duplicate = item.status { return true }; return false }

    var body: some View {
        HStack(spacing: 12) {
            DiscIcon(isDVD: item.isDVD, size: 36, dimmed: isDuplicate)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 2).repeatForever(autoreverses: false) : .default, value: spinning)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    TextField("Game name", text: $item.name)
                        .textFieldStyle(.plain)
                        .font(.body.weight(.medium))
                        .disabled(!editable)
                        .onChange(of: item.name) { _, n in if n.utf8.count > 64 { item.name = String(n.prefix(64)) } }
                    Spacer(minLength: 8)
                    Picker("", selection: $item.isDVD) {
                        Text("CD").tag(false)
                        Text("DVD").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .disabled(!editable)
                    Text(item.sizeText).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        .frame(minWidth: 64, alignment: .trailing)
                }
                HStack(spacing: 8) {
                    Pill(text: item.startup.isEmpty ? "No ID" : item.startup, mono: true)
                    StatusView(status: item.status) { store.installAnyway(item.id) }
                }
            }
            Button {
                store.removeFromQueue([item.id])
            } label: {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering && !spinning ? 1 : 0)
            .help("Remove from queue")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.background.secondary, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(border, lineWidth: spinning ? 1.5 : 0.5))
        .onHover { hovering = $0 }
    }

    private var spinning: Bool { if case .installing = item.status { return true }; return false }

    private var border: Color {
        switch item.status {
        case .installing: return Theme.accent
        case .failed: return .red.opacity(0.6)
        case .done: return .green.opacity(0.5)
        default: return Color.secondary.opacity(0.25)
        }
    }
}

private struct StatusView: View {
    let status: InstallItem.Status
    let installAnyway: () -> Void

    var body: some View {
        switch status {
        case .pending:
            Text("Ready").font(.caption).foregroundStyle(.secondary)
        case .installing(let p, let detail):
            HStack(spacing: 8) {
                ProgressView(value: p).progressViewStyle(.linear).tint(Theme.accent).frame(maxWidth: 220)
                Text("\(Int(p * 100))%").font(.caption.weight(.semibold)).monospacedDigit()
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        case .done:
            Label("Installed", systemImage: "checkmark.circle.fill").font(.caption.weight(.medium)).foregroundStyle(.green)
        case .cancelled:
            Label("Stopped", systemImage: "stop.circle").font(.caption).foregroundStyle(.secondary)
        case .failed(let msg):
            Label(msg, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red).help(msg).lineLimit(1)
        case .duplicate(let reason):
            HStack(spacing: 8) {
                Label(reason, systemImage: "doc.on.doc.fill").font(.caption).foregroundStyle(.orange).lineLimit(1)
                Button("Install Anyway", action: installAnyway).controlSize(.small)
            }
        }
    }
}
