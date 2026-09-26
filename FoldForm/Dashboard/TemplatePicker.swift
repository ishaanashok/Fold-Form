import SwiftUI

/// Choosing what a new design starts from.
struct TemplatePicker: View {
    var onPick: (PartProfileKind) -> Void
    @Environment(\.dismiss) private var dismiss
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(PartProfileKind.allCases) { kind in
                        Button {
                            dismiss()
                            onPick(kind)
                        } label: {
                            VStack(spacing: 8) {
                                preview(for: kind)
                                    .frame(height: 96)
                                Text(kind.rawValue).font(.system(.subheadline, design: .rounded, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(12)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("template-\(kind.rawValue)")
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("New design")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder private func preview(for kind: PartProfileKind) -> some View {
        if let image = TemplatePreviews.image(for: kind) {
            Image(uiImage: image).resizable().scaledToFit()
        } else {
            Image(systemName: "cube.transparent").font(.largeTitle).foregroundStyle(.secondary)
        }
    }
}

@MainActor
enum TemplatePreviews {
    private static var cache: [PartProfileKind: UIImage] = [:]

    static func image(for kind: PartProfileKind) -> UIImage? {
        if let cached = cache[kind] { return cached }
        let capture = DesignContent.template(kind)
        let image = ThumbnailRenderer.render(capture.bodies.map { .init(mesh: $0.mesh, rgb: ThumbnailRenderer.defaultRGB) },
                                             size: CGSize(width: 240, height: 180))
        if let image { cache[kind] = image }
        return image
    }
}
