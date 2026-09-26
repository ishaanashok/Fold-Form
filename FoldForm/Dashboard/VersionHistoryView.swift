import SwiftUI

struct VersionHistoryView: View {
    @ObservedObject var library: DesignLibrary
    let design: DesignManifest
    /// Called after a restore with the design's new contents, so the app can open it.
    var onRestored: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [DesignVersion] = []
    @State private var showSave = false
    @State private var name = ""
    @State private var note = ""
    @State private var confirming: DesignVersion?

    var body: some View {
        NavigationStack {
            Group {
                if versions.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 44)).foregroundStyle(.secondary)
                        Text("No versions yet").font(.headline)
                        Text("Save a version to keep a copy you can come back to. A checkpoint is also saved when you close a design you changed.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 30)
                    }
                } else {
                    List {
                        ForEach(versions) { version in
                            row(version)
                                .swipeActions {
                                    Button("Delete", role: .destructive) { library.deleteVersion(version.id, of: design.id); reload() }
                                }
                        }
                    }
                }
            }
            .navigationTitle("Version history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save version") { name = ""; note = ""; showSave = true }.accessibilityIdentifier("saveVersionButton")
                }
            }
            .alert("Save version", isPresented: $showSave) {
                TextField("Name", text: $name)
                TextField("Note (optional)", text: $note)
                Button("Save") { library.saveVersion(of: design.id, name: name, note: note, automatic: false); reload() }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Restore \"\(confirming?.name ?? "")\"?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
                Button("Restore") {
                    if let confirming, (try? library.restoreVersion(confirming.id, of: design.id)) != nil {
                        dismiss()
                        onRestored(design.id)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Your current design is saved as a version first, so you can go back.") }
        }
        .onAppear(perform: reload)
    }

    private func reload() { versions = library.versions(of: design.id) }

    private func row(_ version: DesignVersion) -> some View {
        HStack(spacing: 12) {
            Group {
                if let image = library.versionThumbnail(version.id, of: design.id) { Image(uiImage: image).resizable().scaledToFit() }
                else { Image(systemName: "cube.transparent").foregroundStyle(.secondary) }
            }
            .frame(width: 64, height: 48)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(version.name).font(.subheadline.weight(.semibold))
                    if version.isAutomatic { Text("Auto").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.secondary.opacity(0.2), in: Capsule()) }
                }
                Text(version.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                Text("\(version.partCount) part\(version.partCount == 1 ? "" : "s")" + (version.note.isEmpty ? "" : " · \(version.note)"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Restore") { confirming = version }.buttonStyle(.bordered).controlSize(.small)
        }
    }
}
