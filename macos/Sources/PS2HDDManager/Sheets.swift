import SwiftUI

struct FormatSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let drive: Drive

    @State private var confirmText = ""
    @State private var createOPL = true

    /// The user must type the disk identifier, so a slip of the mouse can't wipe the wrong drive.
    private var confirmToken: String { drive.identifier == Tools.testDriveID ? "test" : drive.identifier }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Format “\(drive.displayName)” for PS2?", systemImage: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .symbolRenderingMode(.multicolor)

            VStack(alignment: .leading, spacing: 6) {
                Text("Everything on this \(drive.sizeText) drive will be erased and replaced with a PlayStation 2 APA partition table.")
                if !drive.volumeNames.isEmpty {
                    Text("Volumes that will be destroyed: \(drive.volumeNames.joined(separator: ", "))")
                        .foregroundStyle(.red)
                }
                Text("After formatting, macOS will no longer be able to read this drive; it may offer to initialize it. Choose Ignore.")
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

            Toggle("Create a +OPL partition for Open PS2 Loader settings", isOn: $createOPL)

            VStack(alignment: .leading, spacing: 4) {
                Text("Type **\(confirmToken)** to confirm:")
                TextField(confirmToken, text: $confirmText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Erase and Format", role: .destructive) {
                    let opl = createOPL
                    dismiss()
                    Task { await store.format(drive, createOPLPartition: opl) }
                }
                .disabled(confirmText != confirmToken)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

struct RenameSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let game: Game
    let drive: Drive

    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Game").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
                .onSubmit(save)
            Text("\(name.utf8.count)/64 bytes").font(.caption).foregroundStyle(name.utf8.count > 64 ? .red : .secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name.utf8.count > 64)
            }
        }
        .padding(20)
        .onAppear { name = game.name }
    }

    private func save() {
        let n = name
        dismiss()
        Task { await store.rename(game, to: n, on: drive) }
    }
}
