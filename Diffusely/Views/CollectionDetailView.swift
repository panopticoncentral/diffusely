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

    // Author drill-ins push Routes onto the enclosing stack (this view is
    // itself pushed via a value-based NavigationLink from CollectionsView, so
    // router pushes deepen the stack instead of clobbering it).
    @EnvironmentObject private var router: NavigationRouter

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 0) {
                    // Sync progress indicator
                    if let syncService = syncService,
                       let progress = syncService.syncProgress[collection.id] {
                        SyncProgressView(progress: progress) {
                            Task { await refreshContent() }
                        }
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
                .padding(.bottom, 20)
            }
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
            .onReceive(NotificationCenter.default.publisher(for: .collectionMembershipChanged)) { notification in
                // Only reload if the change was for this collection (the userInfo's
                // collectionId matches ours). Otherwise it's noise from a sheet open
                // for an item in a different collection.
                if let changedId = notification.userInfo?["collectionId"] as? Int,
                   changedId == collection.id {
                    Task { await reloadContent() }
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
        // A real navigation title replaces the former in-content 34pt header.
        // On iOS that header was faked under an inline bar with a hard-coded
        // 100pt top padding that broke in landscape / Stage Manager; on macOS
        // the window/toolbar title was left blank. `.navigationTitle` fixes both.
        .navigationTitle(collection.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refreshContent() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                #if os(iOS)
                // macOS ⌘R is owned by the View ▸ Refresh menu command (driven
                // by the refreshFeed focused value below).
                .keyboardShortcut("r")
                #endif
                .disabled(syncService?.isSyncing(collectionId: collection.id) == true)
                .help("Refresh collection contents")
            }
            ToolbarItem(placement: .primaryAction) {
                CollectionSortMenu(selectedSort: $selectedSort)
            }
        }
        #if os(macOS)
        .focusedSceneValue(\.refreshFeed, RefreshFeedAction { Task { await refreshContent() } })
        #endif
    }

    // MARK: - Views

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
                showsItemContextMenus: true
            )
            .padding(.bottom, 8)
        case .flatPosts(let posts):
            AuthorContentGrid(
                images: [],
                posts: posts,
                collectionType: "Post",
                showsItemContextMenus: true
            )
            .padding(.bottom, 8)
        }
    }

    /// Drill into an author's content, stacking on top of this view.
    private func selectAuthor(_ author: CivitaiUser) {
        router.push(.user(author))
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
                            showsItemContextMenus: true
                        )
                        .padding(.bottom, 8)
                    }
                } header: {
                    AuthorSectionHeader(
                        author: group.author,
                        itemCount: group.itemCount,
                        isExpanded: expandedAuthors.contains(group.id),
                        onSelectAuthor: { selectAuthor(group.author) },
                        onToggleCollapse: { toggleAuthor(group.id) }
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
                    // Expand all authors by default on first load, minus any the
                    // user previously collapsed (persisted per collection).
                    let collapsed = CollapsedAuthorsStore.load(collectionId: collection.id)
                    expandedAuthors = Set(groups.map { $0.id }).subtracting(collapsed)
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

        // Wait for the sync to finish, then refresh ONCE.
        //
        // We deliberately do NOT rebuild the grid on a timer while syncing.
        // `reloadContent()` reassigns `content`, which re-packs the MasonryGrid and
        // restarts every in-flight image load. The sync grows/re-sorts the item set
        // and runs for tens of seconds (it retries and individual page fetches can
        // time out), so a per-second reload caught on-screen cells in a relentless
        // rebuild storm — their image loads never settled and the tiles stayed on a
        // permanent grey spinner. Cached items are already on screen from the
        // initial `.task` load; synced updates land when the sync completes.
        Task {
            while syncService.isSyncing(collectionId: collection.id) {
                try? await Task.sleep(for: .seconds(1))
            }
            await reloadContent()
        }
    }

    private func refreshContent() async {
        // Pull-to-refresh forces a full re-sync from the beginning
        guard let persistenceService = persistenceService else { return }

        // Clear existing cursor to force full re-sync
        persistenceService.updateSyncCursor(for: collection.id, cursor: nil)

        startSync(force: true)

        // Keep the pull-to-refresh spinner up until the sync completes.
        // `startSync` kicks off an async sync and returns immediately, so
        // awaiting here is what ties the spinner's lifetime to the real work.
        while syncService?.isSyncing(collectionId: collection.id) == true {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func toggleAuthor(_ authorId: Int) {
        if expandedAuthors.contains(authorId) {
            expandedAuthors.remove(authorId)
        } else {
            expandedAuthors.insert(authorId)
        }
        persistCollapsedAuthors()
    }

    /// Persists the collapsed set (all current authors minus the expanded ones)
    /// so the user's collapse choices survive leaving and reopening the view.
    private func persistCollapsedAuthors() {
        guard case .grouped(let groups) = content else { return }
        let collapsed = Set(groups.map { $0.id }).subtracting(expandedAuthors)
        CollapsedAuthorsStore.save(collapsed, collectionId: collection.id)
    }
}
