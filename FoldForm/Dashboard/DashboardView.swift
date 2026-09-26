import SwiftUI

struct DashboardView: View {
    @ObservedObject var library: DesignLibrary
    @ObservedObject var subscriptions: SubscriptionContext
    var onOpen: (UUID) -> Void

    @State private var showTemplates = false
    @State private var renaming: DesignManifest?
    @State private var renameText = ""
    @State private var deleting: DesignManifest?
    @State private var historyFor: DesignManifest?
    @State private var sharingFor: DesignManifest?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var toastDismiss: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    StatsHeader(stats: library.stats)
                    FolderBar(library: library, showsShared: true, onNewFolder: { newFolderName = ""; showNewFolder = true })
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Designs")
            .searchable(text: $library.query.text, prompt: "Search designs")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        AccountView(entitlements: subscriptions.entitlements, service: subscriptions.service, usageLimiter: subscriptions.usageLimiter)
                    } label: {
                        Label("Account", systemImage: "person.crop.circle")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityIdentifier("accountButton")
                }
                ToolbarItem(placement: .topBarTrailing) { sortMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showTemplates = true } label: { Image(systemName: "plus.circle.fill") }
                        .accessibilityIdentifier("newDesignButton")
                        .accessibilityLabel("New design")
                }
            }
        }
        .sheet(isPresented: $showTemplates) {
            TemplatePicker { kind in
                if let design = library.createDesign(template: kind) { onOpen(design.id) }
            }
        }
        .sheet(item: $historyFor) { design in
            VersionHistoryView(library: library, design: design, onRestored: onOpen)
        }
        .sheet(item: $sharingFor) { ShareView(library: library, design: $0) }
        .alert("Rename design", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let renaming { library.rename(renaming.id, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { if let folder = library.createFolder(newFolderName) { library.query.filter = .folder(folder.id) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \"\(deleting?.name ?? "")\"?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let deleting { library.delete(deleting.id); scheduleToastDismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("You can undo this for a few seconds.") }
        .overlay(alignment: .bottom) { toast }
        .animation(.easeInOut(duration: 0.2), value: library.recentlyDeleted?.id)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        let visible = library.visibleDesigns
        if library.designs.isEmpty && library.unreadable.isEmpty {
            emptyState
        } else if visible.isEmpty && library.unreadable.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                Text("No designs match").font(.headline)
                Text("Try a different search or filter.").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.top, 60)
        } else {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(visible) { design in
                    DesignCard(
                        design: design,
                        image: library.thumbnail(for: design.id),
                        folderName: library.folderName(design.folderID),
                        isShared: library.sharedIDs.contains(design.id),
                        onToggleFavourite: { library.setFavourite(design.id, !design.isFavourite) }
                    )
                    .onTapGesture { onOpen(design.id) }
                    .contextMenu { menu(for: design) }
                }
                ForEach(library.unreadable, id: \.self) { id in unreadableCard(id) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "cube.transparent").font(.system(size: 54)).foregroundStyle(Color.accentColor)
            Text("No designs yet").font(.system(.title2, design: .rounded, weight: .bold))
            Text("Start a design and it will be saved here automatically.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { showTemplates = true } label: {
                Label("Start your first design", systemImage: "plus")
                    .font(.headline).padding(.horizontal, 20).padding(.vertical, 12)
                    .background(Color.accentColor, in: Capsule()).foregroundStyle(.white)
            }
            .accessibilityIdentifier("startFirstDesignButton")
        }
        .frame(maxWidth: .infinity).padding(.top, 50)
    }

    private func unreadableCard(_ id: UUID) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title).foregroundStyle(.orange)
            Text("Couldn't open").font(.subheadline.weight(.semibold))
            Button("Delete", role: .destructive) { library.removeUnreadable(id) }.font(.footnote)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder private func menu(for design: DesignManifest) -> some View {
        Button("Open", systemImage: "arrow.up.right.square") { onOpen(design.id) }
        Button("Rename", systemImage: "pencil") { renameText = design.name; renaming = design }
        Button("Duplicate", systemImage: "plus.square.on.square") { library.duplicate(design.id) }
        Button(design.isFavourite ? "Remove favourite" : "Favourite", systemImage: design.isFavourite ? "star.slash" : "star") {
            library.setFavourite(design.id, !design.isFavourite)
        }
        Button("Version history", systemImage: "clock.arrow.circlepath") { historyFor = design }
        Button("Share", systemImage: "person.badge.plus") { sharingFor = design }
        Menu("Move to folder", systemImage: "folder") {
            Button("No folder") { library.move(design.id, toFolder: nil) }
            ForEach(library.folders) { folder in Button(folder.name) { library.move(design.id, toFolder: folder.id) } }
        }
        Button("Delete", systemImage: "trash", role: .destructive) { deleting = design }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: Binding(get: { library.query.sort }, set: { library.setSort($0) })) {
                ForEach(DesignSort.allCases) { Text($0.title).tag($0) }
            }
        } label: { Image(systemName: "arrow.up.arrow.down.circle") }
        .accessibilityIdentifier("sortMenu")
        .accessibilityLabel("Sort")
    }

    // MARK: Delete toast

    @ViewBuilder private var toast: some View {
        if let deleted = library.recentlyDeleted {
            HStack(spacing: 14) {
                Text("Deleted \"\(deleted.name)\"").font(.subheadline).lineLimit(1)
                Button("Undo") { library.undoDelete() }.font(.subheadline.weight(.bold))
                    .accessibilityIdentifier("undoDeleteButton")
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func scheduleToastDismiss() {
        toastDismiss?.cancel()
        toastDismiss = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            library.dismissDeletionNotice()
        }
    }
}
