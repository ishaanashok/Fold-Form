import Foundation

enum CollaboratorRole: String, Codable, CaseIterable, Identifiable {
    case viewer, editor
    var id: String { rawValue }
    var title: String { self == .viewer ? "Can view" : "Can edit" }
}

struct Collaborator: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var email: String
    var role: CollaboratorRole
    var invitedAt: Date
}

struct ActivityItem: Identifiable, Equatable {
    var id: UUID
    var who: String
    var text: String
    var at: Date
    var isSample: Bool
}

enum CollaborationError: Error, Equatable, LocalizedError {
    case invalidEmail, alreadyInvited
    var errorDescription: String? {
        switch self {
        case .invalidEmail: return "Enter a valid email address."
        case .alreadyInvited: return "That person is already on this design."
        }
    }
}

/// Sharing and live co-editing. Nothing implements this against a server yet; the only
/// implementation below keeps a local list and sends nothing anywhere.
protocol CollaborationService: AnyObject {
    var isConnected: Bool { get }
    func collaborators(for design: UUID) -> [Collaborator]
    func invite(email: String, role: CollaboratorRole, to design: UUID) throws -> Collaborator
    func remove(_ collaborator: UUID, from design: UUID)
    func setRole(_ role: CollaboratorRole, for collaborator: UUID, in design: UUID)
    func sharedDesignIDs() -> Set<UUID>
    func activity(for design: UUID) -> [ActivityItem]
}

/// Stores invitations in a local file so the sharing screens can be designed and tried. It never
/// contacts anyone: an "invitation" is only a row in that file.
final class LocalPreviewCollaborationService: CollaborationService {
    static let previewBanner = "Preview: not connected to a server"

    private let fileURL: URL
    private let now: () -> Date
    private var byDesign: [UUID: [Collaborator]]

    var isConnected: Bool { false }

    init(fileURL: URL, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        let stored = (try? JSONDecoder().decode([String: [Collaborator]].self, from: Data(contentsOf: fileURL))) ?? [:]
        byDesign = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    private func persist() {
        let stored = Dictionary(uniqueKeysWithValues: byDesign.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(stored) { try? data.write(to: fileURL, options: .atomic) }
    }

    static func normalised(_ email: String) -> String? {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !value.contains(where: \.isWhitespace),
              parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else { return nil }
        return value
    }

    func collaborators(for design: UUID) -> [Collaborator] { byDesign[design] ?? [] }

    func invite(email: String, role: CollaboratorRole, to design: UUID) throws -> Collaborator {
        guard let address = Self.normalised(email) else { throw CollaborationError.invalidEmail }
        guard !collaborators(for: design).contains(where: { $0.email == address }) else { throw CollaborationError.alreadyInvited }
        let name = String(address.split(separator: "@")[0]).capitalized
        let person = Collaborator(id: UUID(), name: name, email: address, role: role, invitedAt: now())
        byDesign[design, default: []].append(person)
        persist()
        return person
    }

    func remove(_ collaborator: UUID, from design: UUID) {
        byDesign[design]?.removeAll { $0.id == collaborator }
        if byDesign[design]?.isEmpty == true { byDesign[design] = nil }
        persist()
    }

    func setRole(_ role: CollaboratorRole, for collaborator: UUID, in design: UUID) {
        guard let index = byDesign[design]?.firstIndex(where: { $0.id == collaborator }) else { return }
        byDesign[design]?[index].role = role
        persist()
    }

    func sharedDesignIDs() -> Set<UUID> { Set(byDesign.filter { !$0.value.isEmpty }.keys) }

    /// Made-up entries for the people invited, so the feed can be designed. Every one is marked sample.
    func activity(for design: UUID) -> [ActivityItem] {
        collaborators(for: design).flatMap { person -> [ActivityItem] in
            let texts = person.role == .editor ? ["joined the design", "edited a part"] : ["joined the design", "viewed the design"]
            return texts.enumerated().map { offset, text in
                ActivityItem(id: UUID(), who: person.name, text: text, at: person.invitedAt.addingTimeInterval(Double(offset) * 600), isSample: true)
            }
        }
        .sorted { $0.at > $1.at }
    }
}
