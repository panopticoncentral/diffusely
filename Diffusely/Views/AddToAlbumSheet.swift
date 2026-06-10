import SwiftUI

/// Sheet for placing the given item IDs into an existing album or a brand-new one.
/// Calls back through `LibraryStore.albumService` and bumps `albumsVersion`.
struct AddToAlbumSheet: View {
    let itemIDs: [Int]
    let summaries: [LibrarySortService.AlbumSummary]
    /// Called after items are actually added (existing album or newly created one),
    /// but NOT on Cancel. Lets the presenter clear its selection / exit select mode.
    var onAdded: () -> Void = {}
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var creatingNew = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            Group {
                if summaries.isEmpty {
                    emptyState
                } else {
                    albumList
                }
            }
            .navigationTitle(itemIDs.isEmpty ? "New Album" : "Add to Album")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
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
                ForEach(summaries) { album in
                    Button {
                        add(to: album.id)
                    } label: {
                        HStack {
                            Text(album.name)
                            Spacer()
                            Text("\(album.count)").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func createAlbum() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = ""
        guard !name.isEmpty else { return }
        Task {
            let id = await store.albumService.createAlbum(name: name)
            await store.albumService.addItems(itemIDs, toAlbum: id)
            store.notifyAlbumsChanged()
            onAdded()
            dismiss()
        }
    }

    private func add(to albumID: UUID) {
        Task {
            await store.albumService.addItems(itemIDs, toAlbum: albumID)
            store.notifyAlbumsChanged()
            onAdded()
            dismiss()
        }
    }
}
