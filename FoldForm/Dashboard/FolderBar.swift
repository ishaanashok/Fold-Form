import SwiftUI

struct FolderBar: View {
    @ObservedObject var library: DesignLibrary
    var showsShared = false
    var onNewFolder: () -> Void
    @State private var renaming: DesignFolder?
    @State private var renameText = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", "square.grid.2x2", .all)
                chip("Favourites", "star", .favourites)
                if showsShared { chip("Shared", "person.2", .shared) }
                ForEach(library.folders) { folder in
                    chip(folder.name, "folder", .folder(folder.id))
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") { renameText = folder.name; renaming = folder }
                            Button("Delete folder", systemImage: "trash", role: .destructive) { library.deleteFolder(folder.id) }
                        }
                }
                Button(action: onNewFolder) {
                    Label("Folder", systemImage: "plus")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("newFolderButton")
            }
        }
        .alert("Rename folder", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let renaming { library.renameFolder(renaming.id, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func chip(_ title: String, _ symbol: String, _ filter: DesignFilter) -> some View {
        let selected = library.query.filter == filter
        return Button { library.query.filter = filter } label: {
            Label(title, systemImage: symbol)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
