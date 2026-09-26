import SwiftUI

struct DesignCard: View {
    let design: DesignManifest
    let image: UIImage?
    let folderName: String?
    var isShared = false
    var onToggleFavourite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [Color(.tertiarySystemGroupedBackground), Color.accentColor.opacity(0.14)], startPoint: .topLeading, endPoint: .bottomTrailing))
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().padding(12)
                } else {
                    Image(systemName: "cube.transparent").font(.system(size: 34)).foregroundStyle(.secondary)
                }
                Button(action: onToggleFavourite) {
                    Image(systemName: design.isFavourite ? "star.fill" : "star")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(design.isFavourite ? Color.orange : Color.secondary)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel(design.isFavourite ? "Remove from favourites" : "Add to favourites")
            }
            .aspectRatio(4 / 3, contentMode: .fit)

            VStack(alignment: .leading, spacing: 3) {
                Text(design.name)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(design.modifiedAt, style: .relative)
                    Text("·")
                    Text("\(design.partCount) part\(design.partCount == 1 ? "" : "s")")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if folderName != nil || isShared {
                    HStack(spacing: 8) {
                        if let folderName { Label(folderName, systemImage: "folder.fill") }
                        if isShared { Label("Shared", systemImage: "person.2.fill") }
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("designCard-\(design.name)")
    }
}
