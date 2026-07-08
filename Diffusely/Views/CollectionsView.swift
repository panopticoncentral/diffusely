import SwiftUI
import SwiftData

#if os(macOS)
/// Lets the File ▸ New Collection menu command (in `DiffuselyApp`) trigger the
/// create-collection sheet in whichever `CollectionsView` is frontmost, so ⌘N
/// belongs to a real menu item instead of colliding with the WindowGroup's
/// default File ▸ New Window.
struct NewCollectionAction {
    let perform: () -> Void
    func callAsFunction() { perform() }
}

struct NewCollectionActionKey: FocusedValueKey {
    typealias Value = NewCollectionAction
}

extension FocusedValues {
    var newCollection: NewCollectionAction? {
        get { self[NewCollectionActionKey.self] }
        set { self[NewCollectionActionKey.self] = newValue }
    }
}
#endif

struct CollectionsView: View {
    @StateObject private var apiKeyManager = APIKeyManager.shared
    @StateObject private var civitaiService = CivitaiService()
    @Environment(\.modelContext) private var modelContext
    @State private var persistenceService: CollectionPersistenceService?
    @State private var listSyncService: CollectionListSyncService?
    @State private var showingSettings = false
    @State private var showingCreateCollection = false
    @State private var collections: [CivitaiCollection] = []  // from local cache
    @State private var previewImages: [Int: CivitaiImage] = [:]  // collectionId -> preview image

    // Filter to only show Image and Post collections
    var filteredCollections: [CivitaiCollection] {
        collections.filter { collection in
            if let type = collection.type {
                return type == "Image" || type == "Post"
            }
            return false
        }
    }

    // Adaptive sizing keeps tiles at a sensible size across phone/iPad/Mac.
    // Two flexible columns would let each square stretch to half the window
    // width on a wide Mac, producing huge tiles.
    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 12)
    ]

    var body: some View {
        collectionsContent
    }

    @ViewBuilder
    private var collectionsContent: some View {
        #if os(iOS)
        NavigationStack {
            collectionsInner
        }
        #else
        collectionsInner
        #endif
    }

    @ViewBuilder
    private var collectionsInner: some View {
        Group {
                if !apiKeyManager.hasAPIKey {
                    // Show prompt to add API key
                    VStack(spacing: 20) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)

                        Text("API Key Required")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("Enter your Civitai API key in Settings to access your collections")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        Button(action: {
                            showingSettings = true
                        }) {
                            Label("Open Settings", systemImage: "gear")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    .padding()
                } else if !filteredCollections.isEmpty {
                    // Cache-first: render the cached list instantly. A
                    // background/pull refresh shows a subtle inline indicator
                    // but never replaces the grid or shows an error screen.
                    ScrollView {
                        VStack(spacing: 0) {
                            if let progress = listSyncService?.progress,
                               !progress.isComplete {
                                SyncProgressView(progress: progress)
                            }

                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(filteredCollections) { collection in
                                    NavigationLink(destination: CollectionDetailView(collection: collection)) {
                                        CollectionCard(
                                            collection: collection,
                                            previewImage: previewImages[collection.id]
                                        )
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                    }
                } else if let error = listSyncService?.progress?.lastError {
                    // Empty cache AND the fetch failed — only now is a full
                    // error screen warranted.
                    VStack(spacing: 20) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)

                        Text("Error Loading Collections")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text(error.localizedDescription)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        Button("Retry") {
                            forceListRefresh()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else if listSyncService?.progress?.isComplete == true {
                    VStack(spacing: 20) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)

                        Text("No Collections")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("You don't have any image or post collections yet")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .padding()
                } else {
                    ProgressView("Loading collections...")
                }
            }
            .navigationTitle("Collections")
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingCreateCollection) {
                CreateCollectionView { _ in
                    forceListRefresh()
                }
            }
            .toolbar {
                if apiKeyManager.hasAPIKey {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingCreateCollection = true
                        } label: {
                            Label("New Collection", systemImage: "plus")
                        }
                        #if os(iOS)
                        // On macOS ⌘N is owned by the File ▸ New Collection menu
                        // command (see DiffuselyApp) so it doesn't collide with
                        // the WindowGroup's default New Window. iOS has no such
                        // conflict, so the toolbar button keeps the shortcut for
                        // hardware-keyboard users.
                        .keyboardShortcut("n")
                        #endif
                        .help("Create a new collection")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            forceListRefresh()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        #if os(iOS)
                        // On macOS ⌘R is owned by the View ▸ Refresh menu command
                        // (driven by the refreshFeed focused value below) so the
                        // menu item is enabled instead of appearing disabled while
                        // a hidden toolbar shortcut secretly handles the key.
                        .keyboardShortcut("r")
                        #endif
                        .disabled(listSyncService?.isSyncing == true)
                        .help("Refresh collections")
                    }
                }
            }
            .refreshable {
                forceListRefresh()
                // Keep the pull-to-refresh spinner up until the sync actually
                // finishes. `forceListRefresh()` kicks off an async sync and
                // returns immediately, so awaiting here is what ties the
                // spinner's lifetime to the real work.
                while listSyncService?.isSyncing == true {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            #if os(macOS)
            .focusedSceneValue(
                \.newCollection,
                apiKeyManager.hasAPIKey ? NewCollectionAction { showingCreateCollection = true } : nil
            )
            // Publish Refresh so the single View ▸ Refresh menu item (⌘R) works
            // while Collections is frontmost, instead of the item showing disabled.
            .focusedSceneValue(
                \.refreshFeed,
                apiKeyManager.hasAPIKey ? RefreshFeedAction { forceListRefresh() } : nil
            )
            #endif
            .task {
                guard apiKeyManager.hasAPIKey else { return }
                initializeServices()
                loadFromCache()
                await loadPreviewImages()
                startListSyncIfNeeded()
            }
            .onDisappear {
                // Stop the retry/backoff loop when leaving the screen.
                listSyncService?.cancelSync()
            }
    }

    private func initializeServices() {
        guard persistenceService == nil else { return }
        let persistence = CollectionPersistenceService(modelContext: modelContext)
        persistenceService = persistence
        listSyncService = CollectionListSyncService(
            civitaiService: civitaiService,
            persistenceService: persistence
        )
    }

    /// Loads the cached collection list (instant — no network).
    private func loadFromCache() {
        guard let persistenceService = persistenceService else { return }
        collections = persistenceService.getUserListCollections().map { $0.toCivitaiCollection() }
    }

    /// Background-refreshes only when the cached list is stale (>5 min) or empty.
    private func startListSyncIfNeeded() {
        guard let persistenceService = persistenceService else { return }
        guard persistenceService.listNeedsSync(staleAfter: 300) else {
            print("[ListSync] Skipping — cached collection list is recent")
            return
        }
        startListSync()
    }

    /// Pull-to-refresh / Retry: refresh regardless of staleness.
    private func forceListRefresh() {
        startListSync()
    }

    private func startListSync() {
        guard let listSyncService = listSyncService else { return }
        listSyncService.startSync()

        // Live-refresh the grid from cache as the sync writes rows, then a
        // final reload on completion. Mirrors CollectionDetailView.startSync.
        Task {
            while listSyncService.isSyncing {
                try? await Task.sleep(for: .seconds(1))
                loadFromCache()
                await loadPreviewImages()
            }
            loadFromCache()
            await loadPreviewImages()
        }
    }

    private func loadPreviewImages() async {
        await withTaskGroup(of: (Int, CivitaiImage?).self) { group in
            for collection in filteredCollections {
                // Skip if collection already has a cover image
                if collection.image?.fullImageURL != nil {
                    continue
                }

                group.addTask {
                    guard let type = collection.type else { return (collection.id, nil) }
                    let image = try? await self.civitaiService.fetchCollectionPreviewImage(
                        collectionId: collection.id,
                        collectionType: type
                    )
                    return (collection.id, image)
                }
            }

            for await (collectionId, image) in group {
                if let image = image {
                    previewImages[collectionId] = image
                }
            }
        }
    }
}

struct CollectionCard: View {
    let collection: CivitaiCollection
    var previewImage: CivitaiImage?

    private var typeIcon: String {
        switch collection.type {
        case "Image":
            return "photo.stack"
        case "Post":
            return "square.stack.3d.up"
        default:
            return "folder"
        }
    }

    private var typeColor: Color {
        switch collection.type {
        case "Image":
            return .blue
        case "Post":
            return .purple
        default:
            return .gray
        }
    }

    /// Returns the URL to display: collection cover, preview image, or nil
    private var displayImageURL: String? {
        // First try the collection's explicit cover image
        if let coverURL = collection.image?.fullImageURL {
            return coverURL
        }
        // Fall back to fetched preview image (use thumbnailURL for static image even if it's a video)
        if let preview = previewImage {
            return preview.thumbnailURL
        }
        return nil
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Background image or placeholder
            GeometryReader { geometry in
                if let imageURL = displayImageURL {
                    CachedAsyncImage(url: imageURL)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    // Gradient placeholder when no cover image
                    LinearGradient(
                        colors: [typeColor.opacity(0.3), typeColor.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .overlay(
                        Image(systemName: typeIcon)
                            .font(.system(size: 40))
                            .foregroundColor(.white.opacity(0.5))
                    )
                }
            }

            // Bottom gradient overlay for text readability
            LinearGradient(
                colors: [.clear, .black.opacity(0.7), .black.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 100)

            // Content overlay
            VStack(alignment: .leading, spacing: 4) {
                Spacer()

                Text(collection.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 8) {
                    // Type badge
                    HStack(spacing: 3) {
                        Image(systemName: typeIcon)
                            .font(.system(size: 9))
                        Text(collection.type ?? "")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(typeColor.opacity(0.9))
                    .foregroundColor(.white)
                    .cornerRadius(4)

                    // Image count
                    if let imageCount = collection.imageCount, imageCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "photo")
                                .font(.system(size: 9))
                            Text("\(imageCount)")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.white.opacity(0.8))
                    }

                    Spacer()
                }
            }
            .padding(10)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
    }
}
