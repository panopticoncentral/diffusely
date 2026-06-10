import SwiftUI

/// Sheet for managing which albums the given item IDs belong to. Each album row
/// shows a tri-state checkmark — none / some / all of the selection is in that
/// album. Tapping a row adds the whole selection to the album, or removes the
/// whole selection when every item is already a member. Mutations apply
/// immediately through `LibraryStore.albumService`; "Done" just dismisses.
///
/// With empty `itemIDs` (the Albums browser "New Album" tile) the sheet is a
/// create-only flow: albums are listed for reference but have no checkmarks,
/// and creating an album dismisses immediately.
struct ManageAlbumsSheet: View {
    let itemIDs: [Int]
    /// Called on dismissal if any membership change was applied (but not after
    /// a no-op Done). Lets the presenter clear its selection / exit select mode.
    var onChanged: () -> Void

    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    /// Local working copies, seeded from the presenter at presentation time and
    /// then maintained optimistically as toggles apply — so the sheet reflects
    /// each change instantly without a round-trip through the index.
    @State private var albums: [LibrarySortService.AlbumSummary]
    /// How many of `itemIDs` are currently members of each album (absent = 0).
    @State private var memberCounts: [UUID: Int]
    /// The membership at presentation time, used to adjust each album's
    /// displayed total as toggles move the selection in and out.
    private let initialMemberCounts: [UUID: Int]

    @State private var creatingNew = false
    @State private var newName = ""
    @State private var didChange = false

    init(
        itemIDs: [Int],
        summaries: [LibrarySortService.AlbumSummary],
        membershipCounts: [UUID: Int],
        onChanged: @escaping () -> Void = {}
    ) {
        self.itemIDs = itemIDs
        self.onChanged = onChanged
        self.initialMemberCounts = membershipCounts
        _albums = State(initialValue: summaries)
        _memberCounts = State(initialValue: membershipCounts)
    }

    var body: some View {
        NavigationStack {
            Group {
                if albums.isEmpty {
                    emptyState
                } else {
                    albumList
                }
            }
            .navigationTitle(itemIDs.isEmpty ? "New Album" : "Manage Albums")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                // Always-visible create affordance, so a new album can be made
                // even when no albums exist yet (the list would otherwise be empty).
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        creatingNew = true
                    } label: {
                        Label("New Album", systemImage: "plus")
                    }
                }
            }
            .alert("New Album", isPresented: $creatingNew) {
                TextField("Album name", text: $newName)
                Button("Cancel", role: .cancel) { newName = "" }
                Button("Create") { createAlbum() }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        // Fire on any dismissal path (Done button or swipe-down) so the
        // presenter exits select mode whenever changes were actually made.
        .onDisappear {
            if didChange { onChanged() }
        }
        // macOS sheets don't impose a size, so a `List` inside collapses to zero
        // content height and renders no rows. Give the sheet a concrete size so the
        // album list has room to lay out. (iOS sheets size themselves correctly.)
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 480, idealHeight: 560)
        #endif
    }

    /// Shown when the user has no albums yet: a clear call-to-action instead of an
    /// empty list, so "how do I create an album?" is obvious.
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No Albums Yet")
                .font(.headline)
            Text("Create an album to organize your saved photos and videos.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                creatingNew = true
            } label: {
                Label("Create Album", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var albumList: some View {
        List {
            Section {
                Button {
                    creatingNew = true
                } label: {
                    Label("New Album…", systemImage: "plus.rectangle.on.rectangle")
                }
            }
            Section("Albums") {
                ForEach(albums) { album in
                    if itemIDs.isEmpty {
                        plainRow(album)
                    } else {
                        membershipRow(album)
                    }
                }
            }
        }
    }

    /// Create-only flow: list albums for reference, no membership affordance.
    private func plainRow(_ album: LibrarySortService.AlbumSummary) -> some View {
        HStack {
            Text(album.name)
            Spacer()
            Text("\(album.count)").foregroundStyle(.secondary)
        }
        .foregroundStyle(.secondary)
    }

    private func membershipRow(_ album: LibrarySortService.AlbumSummary) -> some View {
        let inAlbum = memberCounts[album.id] ?? 0
        let allIn = inAlbum == itemIDs.count
        return Button {
            toggleMembership(album.id, allCurrentlyIn: allIn)
        } label: {
            HStack(spacing: 12) {
                // Photos-style tri-state: filled check (all), filled dash (some
                // of a multi-selection), empty circle (none).
                Image(systemName: allIn ? "checkmark.circle.fill"
                                : inAlbum > 0 ? "minus.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(inAlbum > 0 ? Color.accentColor : Color.secondary)
                Text(album.name)
                Spacer()
                Text("\(displayCount(for: album))").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(allIn ? .isSelected : [])
        .accessibilityValue(allIn ? "all selected items in album"
                          : inAlbum > 0 ? "some selected items in album"
                          : "not in album")
    }

    /// The album's displayed total, adjusted live as toggles move the selection
    /// in and out (total at presentation − selection members then + now).
    private func displayCount(for album: LibrarySortService.AlbumSummary) -> Int {
        album.count - (initialMemberCounts[album.id] ?? 0) + (memberCounts[album.id] ?? 0)
    }

    /// None/some → add the whole selection; all → remove the whole selection.
    /// Local state updates optimistically; the service applies the same
    /// idempotent mutation to the sidecars and index.
    private func toggleMembership(_ albumID: UUID, allCurrentlyIn: Bool) {
        memberCounts[albumID] = allCurrentlyIn ? 0 : itemIDs.count
        didChange = true
        Task {
            if allCurrentlyIn {
                await store.albumService.removeItems(itemIDs, fromAlbum: albumID)
            } else {
                await store.albumService.addItems(itemIDs, toAlbum: albumID)
            }
            store.notifyAlbumsChanged()
        }
    }

    private func createAlbum() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = ""
        guard !name.isEmpty else { return }
        Task {
            let id = await store.albumService.createAlbum(name: name)
            if itemIDs.isEmpty {
                // Create-only flow: nothing to manage, so we're done.
                store.notifyAlbumsChanged()
                dismiss()
                return
            }
            await store.albumService.addItems(itemIDs, toAlbum: id)
            store.notifyAlbumsChanged()
            didChange = true
            // Stay open with the new album shown as a fully-checked row, so the
            // user can keep adjusting other memberships.
            withAnimation {
                albums.append(LibrarySortService.AlbumSummary(
                    id: id, name: name, count: 0, coverItem: nil))
                albums.sort { $0.name.lowercased() < $1.name.lowercased() }
                memberCounts[id] = itemIDs.count
            }
        }
    }
}
