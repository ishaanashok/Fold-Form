import SwiftUI

struct PreviewBanner: View {
    var body: some View {
        Label(LocalPreviewCollaborationService.previewBanner, systemImage: "wifi.slash")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("previewBanner")
    }
}

struct ShareView: View {
    @ObservedObject var library: DesignLibrary
    let design: DesignManifest
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var role: CollaboratorRole = .editor
    @State private var people: [Collaborator] = []
    @State private var activity: [ActivityItem] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section { PreviewBanner().listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                Section("People") {
                    personRow(name: "You", detail: "Owner", tint: .accentColor, sample: false)
                    ForEach(people) { person in
                        HStack {
                            avatar(person.name, tint: .purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(person.name).font(.subheadline.weight(.semibold))
                                Text(person.email).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu(person.role.title) {
                                ForEach(CollaboratorRole.allCases) { r in
                                    Button(r.title) { library.collaboration.setRole(r, for: person.id, in: design.id); reload() }
                                }
                                Button("Remove", role: .destructive) { library.collaboration.remove(person.id, from: design.id); reload() }
                            }
                            .font(.footnote)
                        }
                    }
                }
                Section("Invite (stored on this device only)") {
                    TextField("Email address", text: $email)
                        .textInputAutocapitalization(.never).keyboardType(.emailAddress).autocorrectionDisabled()
                        .accessibilityIdentifier("inviteEmailField")
                    Picker("Access", selection: $role) { ForEach(CollaboratorRole.allCases) { Text($0.title).tag($0) } }
                    Button("Add person") { invite() }.accessibilityIdentifier("inviteButton")
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                    Text("Nothing is sent. When a server is connected, people added here will be invited for real.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !activity.isEmpty {
                    Section("Activity") {
                        ForEach(activity) { item in
                            HStack(spacing: 10) {
                                avatar(item.who, tint: .purple)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(item.who) \(item.text)").font(.subheadline)
                                    Text(item.at, style: .relative).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("Sample").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.2), in: Capsule())
                            }
                        }
                    }
                }
            }
            .navigationTitle("Share \"\(design.name)\"")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear(perform: reload)
    }

    private func invite() {
        do {
            _ = try library.collaboration.invite(email: email, role: role, to: design.id)
            email = ""; error = nil
            reload()
        } catch { self.error = error.localizedDescription }
    }

    private func reload() {
        people = library.collaboration.collaborators(for: design.id)
        activity = library.collaboration.activity(for: design.id)
        library.refreshShared()
    }

    private func personRow(name: String, detail: String, tint: Color, sample: Bool) -> some View {
        HStack {
            avatar(name, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func avatar(_ name: String, tint: Color) -> some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(tint.gradient, in: Circle())
    }
}
