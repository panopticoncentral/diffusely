import SwiftUI
import SwiftData

struct CollectionDetailView: View {
    let collection: CivitaiCollection

    @Environment(\.modelContext) private var modelContext
    @StateObject private var civitaiService = CivitaiService()
    @State private var persistenceService: CollectionPersistenceService?
    @State private var syncService: CollectionSyncService?

    // Sorted content state
    @State private var content: CollectionPersistenceService.SortedCollectionContent = .grouped([])
    @State private var selectedSort: CollectionSort = .authorAscending
    // Guards the one-time auto-sync that backfills publish dates for
    // collections cached before date sorting existed.
    @State private var didRequestDateBackfill = false
    @State private var expandedAuthors: Set<Int> = []
    @State private var isInitialLoad = true

    // Removal state
    @State private var pendingRemoval: CollectionItemType?
    @State private var isRemoving = false
    @State private var removalError: String?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isGridLayout: Bool {
        horizontalSizeClass == .regular
    }

    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 2),
            GridItem(.flexible(), spacing: 2),
            GridItem(.flexible(), spacing: 2)
        ]
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 0) {
                    // Header with title and controls
                    headerView

                    // Sync progress indicator
                    if let syncService = syncService,
                       let progress = syncService.syncProgress[collection.id] {
                        SyncProgressView(progress: progress)
                    }

                    // Content - sorted per selectedSort
                    if content.isEmpty && isInitialLoad {
                        loadingView
                    } else if content.isEmpty {
                        emptyView
                    } else {
                        sortedContent
                    }
                }
                #if os(iOS)
                .padding(.top, 100)
                #endif
                .padding(.bottom, 20)
            }
            #if os(iOS)
            .ignoresSafeArea(.all)
            #endif
            .refreshable {
                await refreshContent()
            }
            .task {
                initializeServices()
                await reloadContent()
                startSyncIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("CollectionSyncProgressUpdated"))) { _ in
                Task {
                    await reloadContent()
                }
            }
            .onChange(of: selectedSort) {
                Task { await reloadContent() }
            }
            .onDisappear {
                // Stop the retry/backoff loop when leaving the screen; the
                // saved cursor lets it resume on reopen.
                syncService?.cancelSync(for: collection.id)
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                CollectionSortMenu(selectedSort: $selectedSort)
            }
        }
        .confirmationDialog(
            "Remove from \"\(collection.name)\"?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let item = pendingRemoval {
                    pendingRemoval = nil
                    Task { await performRemoval(item) }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingRemoval = nil
            }
        }
        .alert(
            "Couldn't Remove Item",
            isPresented: Binding(
                get: { removalError != nil },
                set: { if !$0 { removalError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { removalError = nil }
        } message: {
            Text(removalError ?? "")
        }
    }

    // MARK: - Views

    @ViewBuilder
    private var headerView: some View {
        HStack {
            Text(collection.name)
                .font(.system(size: 34, weight: .bold, design: .default))
                .foregroundStyle(.primary)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)
            Spacer()
        }
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading collection...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }

    @ViewBuilder
    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.stack")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("This collection is empty")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }

    @ViewBuilder
    private var sortedContent: some View {
        switch content {
        case .grouped(let groups):
            authorGroupedContent(groups)
        case .flatImages(let images):
            AuthorContentGrid(
                images: images,
                posts: [],
                collectionType: "Image",
                onRequestRemove: { pendingRemoval = $0 }
            )
            .padding(.bottom, 8)
        case .flatPosts(let posts):
            AuthorContentGrid(
                images: [],
                posts: posts,
                collectionType: "Post",
                onRequestRemove: { pendingRemoval = $0 }
            )
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func authorGroupedContent(_ groups: [CollectionPersistenceService.AuthorGroup]) -> some View {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(groups) { group in
                Section {
                    if expandedAuthors.contains(group.id) {
                        AuthorContentGrid(
                            images: group.images,
                            posts: group.posts,
                            collectionType: collection.type ?? "Image",
                            onRequestRemove: { pendingRemoval = $0 }
                        )
                        .padding(.bottom, 8)
                    }
                } header: {
                    AuthorSectionHeader(
                        author: group.author,
                        itemCount: group.itemCount,
                        isExpanded: expandedAuthors.contains(group.id),
                        onTap: { toggleAuthor(group.id) }
                    )
                }
            }
        }
    }

    // MARK: - Actions

    private func initializeServices() {
        persistenceService = CollectionPersistenceService(modelContext: modelContext)
        syncService = CollectionSyncService(
            civitaiService: civitaiService,
            persistenceService: persistenceService!
        )
    }

    /// Rebuilds `content` honoring the current `selectedSort`. Used for the
    /// initial load, sync refreshes, sort changes, and after removals.
    private func reloadContent() async {
        guard let persistenceService = persistenceService else { return }

        let newContent = persistenceService.getSortedContent(
            for: collection.id,
            type: collection.type ?? "Image",
            sort: selectedSort
        )

        await MainActor.run {
            if case .grouped(let groups) = newContent {
                if isInitialLoad {
                    // Expand all authors by default on first load
                    expandedAuthors = Set(groups.map { $0.id })
                } else {
                    // Preserve expansion state, expand newly-seen authors
                    let existingIds: Set<Int>
                    if case .grouped(let oldGroups) = content {
                        existingIds = Set(oldGroups.map { $0.id })
                    } else {
                        existingIds = []
                    }
                    let newAuthorIds = Set(groups.map { $0.id }).subtracting(existingIds)
                    expandedAuthors.formUnion(newAuthorIds)
                }
            }
            content = newContent
            isInitialLoad = false
        }

        // One-time auto-backfill: a date sort is active but some cached
        // items predate date support (no publishedAt was ever stored).
        // Force a full re-sync once to populate publish dates; the sync
        // polling loop re-sorts the list live as dates arrive.
        if !selectedSort.isAuthorGrouped,
           !didRequestDateBackfill,
           let syncService = syncService,
           !syncService.isSyncing(collectionId: collection.id),
           persistenceService.countItemsMissingPublishedDate(
               for: collection.id,
               type: collection.type ?? "Image"
           ) > 0 {
            didRequestDateBackfill = true
            await refreshContent()
        }
    }

    /// Only syncs if data is stale (>5 minutes since last sync) or never synced
    private func startSyncIfNeeded() {
        guard let persistenceService = persistenceService else { return }

        // Check if sync is needed (stale after 5 minutes)
        guard persistenceService.needsSync(for: collection.id, staleAfter: 300) else {
            print("[Sync] Skipping sync - last sync was recent")
            return
        }

        startSync(force: false)
    }

    /// Forces a sync regardless of when last sync occurred
    private func startSync(force: Bool) {
        guard let syncService = syncService else { return }
        syncService.startSync(for: collection)

        // Observe sync progress changes
        Task {
            // Periodically refresh while syncing
            while syncService.isSyncing(collectionId: collection.id) {
                try? await Task.sleep(for: .seconds(1))
                await reloadContent()
            }
            // Final refresh when sync completes
            await reloadContent()
        }
    }

    private func refreshContent() async {
        // Pull-to-refresh forces a full re-sync from the beginning
        guard let persistenceService = persistenceService else { return }

        // Clear existing cursor to force full re-sync
        persistenceService.updateSyncCursor(for: collection.id, cursor: nil)

        startSync(force: true)
    }

    private func performRemoval(_ item: CollectionItemType) async {
        guard let persistenceService = persistenceService else { return }

        isRemoving = true
        defer { isRemoving = false }

        do {
            switch item {
            case .image(let imageId):
                try await civitaiService.removeImageFromCollection(imageId: imageId, collectionId: collection.id)
                persistenceService.removeImage(imageId: imageId, fromCollectionId: collection.id)
            case .post(let postId):
                try await civitaiService.removePostFromCollection(postId: postId, collectionId: collection.id)
                persistenceService.removePost(postId: postId, fromCollectionId: collection.id)
            }
            await reloadContent()
        } catch {
            removalError = "Failed to remove from collection: \(error.localizedDescription)"
        }
    }

    private func toggleAuthor(_ authorId: Int) {
        if expandedAuthors.contains(authorId) {
            expandedAuthors.remove(authorId)
        } else {
            expandedAuthors.insert(authorId)
        }
    }
}
