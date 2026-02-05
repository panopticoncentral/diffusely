import SwiftUI
import SwiftData

struct CollectionDetailView: View {
    let collection: CivitaiCollection

    @Environment(\.modelContext) private var modelContext
    @StateObject private var civitaiService = CivitaiService()
    @State private var persistenceService: CollectionPersistenceService?
    @State private var syncService: CollectionSyncService?

    // Author grouping state
    @State private var authorGroups: [CollectionPersistenceService.AuthorGroup] = []
    @State private var expandedAuthors: Set<Int> = []
    @State private var isInitialLoad = true

    // Filter controls
    @State private var selectedRating: ContentRating = .xxx
    @State private var selectedPeriod: Timeframe = .allTime
    @State private var selectedSort: FeedSort = .newest

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

                    // Content - grouped by author
                    if authorGroups.isEmpty && isInitialLoad {
                        loadingView
                    } else if authorGroups.isEmpty {
                        emptyView
                    } else {
                        authorGroupedContent
                    }
                }
                .padding(.top, 100)
                .padding(.bottom, 20)
            }
            .ignoresSafeArea(.all)
            .refreshable {
                await refreshContent()
            }
            .task {
                initializeServices()
                await loadCachedContent()
                startSyncIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("CollectionSyncProgressUpdated"))) { _ in
                Task {
                    await refreshAuthorGroups()
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
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

            FeedFilterMenu(
                selectedRating: $selectedRating,
                selectedPeriod: $selectedPeriod,
                selectedSort: $selectedSort
            )
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
    private var authorGroupedContent: some View {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(authorGroups) { group in
                Section {
                    if expandedAuthors.contains(group.id) {
                        AuthorContentGrid(
                            images: group.images,
                            posts: group.posts,
                            collectionType: collection.type ?? "Image"
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

    private func loadCachedContent() async {
        guard let persistenceService = persistenceService else { return }

        // Load from persistence
        if collection.type == "Image" {
            authorGroups = persistenceService.getImagesGroupedByAuthor(for: collection.id)
        } else if collection.type == "Post" {
            authorGroups = persistenceService.getPostsGroupedByAuthor(for: collection.id)
        }

        // Expand all authors by default
        expandedAuthors = Set(authorGroups.map { $0.id })

        isInitialLoad = false
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
                await refreshAuthorGroups()
            }
            // Final refresh when sync completes
            await refreshAuthorGroups()
        }
    }

    private func refreshAuthorGroups() async {
        guard let persistenceService = persistenceService else { return }

        let newGroups: [CollectionPersistenceService.AuthorGroup]
        if collection.type == "Image" {
            newGroups = persistenceService.getImagesGroupedByAuthor(for: collection.id)
        } else {
            newGroups = persistenceService.getPostsGroupedByAuthor(for: collection.id)
        }

        // Preserve expansion state for existing authors, expand new ones
        let existingIds = Set(authorGroups.map { $0.id })
        let newAuthorIds = Set(newGroups.map { $0.id }).subtracting(existingIds)

        await MainActor.run {
            authorGroups = newGroups
            expandedAuthors.formUnion(newAuthorIds)
        }
    }

    private func refreshContent() async {
        // Pull-to-refresh forces a full re-sync from the beginning
        guard let persistenceService = persistenceService else { return }

        // Clear existing cursor to force full re-sync
        persistenceService.updateSyncCursor(for: collection.id, cursor: nil)

        startSync(force: true)
    }

    private func toggleAuthor(_ authorId: Int) {
        if expandedAuthors.contains(authorId) {
            expandedAuthors.remove(authorId)
        } else {
            expandedAuthors.insert(authorId)
        }
    }
}
