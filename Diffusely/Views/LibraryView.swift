import SwiftUI
import SwiftData
import Combine

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.modelContext) private var modelContext

    @State private var sortService: LibrarySortService?
    @State private var backfillService: LibraryDateBackfillService?
    @State private var backfillRemaining: Int = 0
    @State private var backfillCancellable: AnyCancellable?
    @State private var content: LibrarySortService.LibrarySortedContent = .flat([])
    @State private var selectedSort: LibrarySort = .dateNewest
    @State private var expandedGroups: Set<String> = []
    @State private var didSeedGroups = false
    @State private var isSelecting = false
    @State private var selectedIDs: Set<Int> = []
    @State private var showingBulkDeleteConfirm = false

    var body: some View {
        content(for: content)
            .navigationTitle("Library")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    LibrarySortMenu(selectedSort: $selectedSort)
                }
            }
            .task {
                store.start()
                initializeServices()
                reloadContent()
                await maybeStartBackfill()
            }
            .onChange(of: selectedSort) {
                reloadContent()
                Task { await maybeStartBackfill() }
            }
            .onChange(of: store.itemCount) {
                reloadContent()
            }
    }

    // MARK: - Render

    // Photos-style: a single lazy grid of square thumbnails. Uniform cell size
    // lets the grid compute its height without laying out every cell, so it
    // virtualizes (only on-screen rows are realized) at any library size — no
    // cap needed. A masonry (variable-height) grid can't virtualize this way.
    private let gridSpacing: CGFloat = 10
    private let gridEdgePadding: CGFloat = 16
    // Column count = floor(viewportWidth / targetTileWidth), min 2. Deriving it
    // from the viewport (not a fixed `adaptive(minimum:)`) keeps the tile size
    // consistent across devices — ≈5 across on a Mac-sized window, ≈2 on a
    // phone. Raise targetTileWidth for bigger pictures / fewer columns.
    private let targetTileWidth: CGFloat = 300
    // Tile shape (width / height). Portrait 3:4 suits a mostly-portrait library
    // better than a square crop. Use 1 for square, 4.0/3.0 for landscape.
    private let tileAspectRatio: CGFloat = 3.0 / 4.0
    @State private var gridColumnCount: Int = 3

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: gridColumnCount)
    }

    @ViewBuilder
    private func content(for content: LibrarySortService.LibrarySortedContent) -> some View {
        if content.isEmpty {
            emptyState
        } else {
            ScrollView {
                if store.iCloudStatus == .unavailable {
                    localOnlyBanner
                }
                if backfillRemaining > 0 {
                    backfillBanner(remaining: backfillRemaining)
                }
                switch content {
                case .flat(let items):
                    LazyVGrid(columns: gridColumns, spacing: gridSpacing) {
                        cells(for: items)
                    }
                    .padding(.horizontal, gridEdgePadding)
                    footer(items: items)
                case .grouped(let groups):
                    LazyVGrid(columns: gridColumns, spacing: gridSpacing, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups) { group in
                            Section {
                                if expandedGroups.contains(group.id) {
                                    cells(for: group.items)
                                }
                            } header: {
                                header(for: group)
                            }
                        }
                    }
                    .padding(.horizontal, gridEdgePadding)
                    footer(items: groups.flatMap { $0.items })
                }
            }
            .background(Color(.systemBackground))
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                let count = max(2, Int(width / targetTileWidth))
                if count != gridColumnCount { gridColumnCount = count }
            }
        }
    }

    @ViewBuilder
    private func cells(for items: [PersistedLibraryItem]) -> some View {
        ForEach(items) { item in
            if isSelecting {
                Button {
                    toggleSelection(item.itemID)
                } label: {
                    selectableThumbnail(for: item)
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink {
                    LibraryDetailView(itemID: item.itemID)
                } label: {
                    thumbnail(for: item)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func header(for group: LibrarySortService.LibraryGroup) -> some View {
        switch group.kind {
        case .author(let username, let avatarURL):
            AuthorSectionHeader(
                author: CivitaiUser(
                    id: stableAuthorID(for: username),
                    username: username,
                    image: avatarURL
                ),
                itemCount: group.items.count,
                isExpanded: expandedGroups.contains(group.id),
                onToggleCollapse: { toggle(group.id) }
            )
        case .checkpoint(let name):
            LibraryGroupHeader(
                icon: "cube.transparent",
                title: name,
                itemCount: group.items.count,
                isExpanded: expandedGroups.contains(group.id),
                onTap: { toggle(group.id) }
            )
        case .bucket(.videos):
            LibraryGroupHeader(
                icon: "film",
                title: "Videos",
                itemCount: group.items.count,
                isExpanded: expandedGroups.contains(group.id),
                onTap: { toggle(group.id) }
            )
        case .bucket(.other):
            LibraryGroupHeader(
                icon: "photo.stack",
                title: "Other",
                itemCount: group.items.count,
                isExpanded: expandedGroups.contains(group.id),
                onTap: { toggle(group.id) }
            )
        case .bucket(.unknownAuthor):
            LibraryGroupHeader(
                icon: "person.fill.questionmark",
                title: "Unknown",
                itemCount: group.items.count,
                isExpanded: expandedGroups.contains(group.id),
                onTap: { toggle(group.id) }
            )
        }
    }

    @ViewBuilder
    private func footer(items: [PersistedLibraryItem]) -> some View {
        Text(itemCountText(for: items))
            .font(.footnote)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
    }

    @ViewBuilder
    private func backfillBanner(remaining: Int) -> some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.7)
            Text("Backfilling publish dates… \(remaining) remaining")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(Color.gray.opacity(0.08))
    }

    private func itemCountText(for items: [PersistedLibraryItem]) -> String {
        let videos = items.filter { $0.isVideo }.count
        let photos = items.count - videos
        var parts: [String] = []
        if photos > 0 { parts.append("\(photos) Photo\(photos == 1 ? "" : "s")") }
        if videos > 0 { parts.append("\(videos) Video\(videos == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    private func thumbnail(for item: PersistedLibraryItem) -> some View {
        Color(.secondarySystemBackground)
            .aspectRatio(tileAspectRatio, contentMode: .fit)
            .overlay {
                LibraryAsyncImage(
                    itemID: item.itemID,
                    mediaFileName: item.mediaFileName,
                    isVideo: item.isVideo,
                    maxDimension: LibraryImageRequest.gridDimension,
                    contentMode: .fill
                )
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if item.isVideo {
                    Image(systemName: "play.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.downloadStatus != .downloaded {
                    Image(systemName: "icloud")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
    }

    /// The grid thumbnail decorated for selection mode: a check badge in the
    /// top-trailing corner and a slight dim when selected.
    private func selectableThumbnail(for item: PersistedLibraryItem) -> some View {
        let isSelected = selectedIDs.contains(item.itemID)
        return thumbnail(for: item)
            .overlay {
                if isSelected {
                    Color.black.opacity(0.25)
                }
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, isSelected ? Color.accentColor : Color.white.opacity(0.6))
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .padding(6)
            }
    }

    private func toggleSelection(_ itemID: Int) {
        if selectedIDs.contains(itemID) {
            selectedIDs.remove(itemID)
        } else {
            selectedIDs.insert(itemID)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("Your Library is Empty")
                .font(.headline)
            Text("Use \"Save to Library\" on any image or video to keep your own iCloud-synced copy.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if store.iCloudStatus == .unavailable {
                Text("iCloud is unavailable - items are saved on this device only.")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var localOnlyBanner: some View {
        Label("iCloud unavailable - saved on this device only", systemImage: "exclamationmark.icloud")
            .font(.caption)
            .foregroundColor(.orange)
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(Color.orange.opacity(0.12))
    }

    // MARK: - Actions

    private func initializeServices() {
        if sortService == nil {
            sortService = LibrarySortService(modelContext: modelContext)
        }
    }

    private func reloadContent() {
        guard let sortService else { return }
        let newContent = sortService.sortedLibraryContent(sort: selectedSort)

        // Seed all groups expanded on first grouped load, and auto-expand any
        // newly-seen groups on later reloads. Safe now that the square LazyVGrid
        // virtualizes — expanded sections only realize their on-screen rows.
        if case .grouped(let groups) = newContent {
            if !didSeedGroups {
                expandedGroups = Set(groups.map { $0.id })
                didSeedGroups = true
            } else {
                let existing: Set<String>
                if case .grouped(let oldGroups) = content {
                    existing = Set(oldGroups.map { $0.id })
                } else {
                    existing = []
                }
                let newlySeen = Set(groups.map { $0.id }).subtracting(existing)
                expandedGroups.formUnion(newlySeen)
            }
        }

        content = newContent
    }

    /// Kick off the publish-date backfill at most once per app session if there
    /// are items without `publishedAt`. The gate lives on `LibraryStore` so it
    /// survives `LibraryView` rebuilds (every navigation into the Library tab
    /// would otherwise restart the backfill and re-show the spinner banner).
    private func maybeStartBackfill() async {
        guard !store.didRunDateBackfillThisSession,
              let sortService else { return }
        guard sortService.countItemsNeedingDateBackfill() > 0 else { return }

        // Resolve the container *before* claiming the gate so a cold-launch
        // race where `itemsDirectory()` isn't ready yet still lets a later
        // view mount retry. Once we have a directory, we're committed.
        guard let dir = try? await LibraryContainer.shared.itemsDirectory() else { return }
        guard !store.didRunDateBackfillThisSession else { return }
        store.markDateBackfillRanThisSession()
        let service = LibraryDateBackfillService(
            indexService: store.indexService,
            itemsDirectory: dir,
            fetcher: CivitaiServiceFetchImageAdapter()
        )
        backfillService = service
        backfillCancellable = service.$remaining.sink { value in
            backfillRemaining = value
        }
        await service.runOnce()
        reloadContent()
    }

    private func toggle(_ groupID: String) {
        if expandedGroups.contains(groupID) {
            expandedGroups.remove(groupID)
        } else {
            expandedGroups.insert(groupID)
        }
    }

    /// Stable surrogate id for `AuthorSectionHeader`, which expects an
    /// `Int` user id. Library author rows only carry the username, so we
    /// hash it into a positive Int for the section header to consume.
    /// The collection view's `AuthorSectionHeader` only uses this for
    /// `Identifiable`-style purposes, not for fetching anything.
    private func stableAuthorID(for username: String) -> Int {
        var hasher = Hasher()
        hasher.combine(username)
        return abs(hasher.finalize() & 0x7FFF_FFFF)
    }
}
