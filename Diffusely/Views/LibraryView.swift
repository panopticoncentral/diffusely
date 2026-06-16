import SwiftUI
import SwiftData
import Combine

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Which slice of the library this instance renders. `.all` is the top-level
    /// Library (and shows the Photos/Albums switcher — added in Task 11); the
    /// other cases are pushed detail screens scoped to an album or the
    /// not-in-any-album complement.
    var filter: AlbumFilter = .all
    /// Title for scoped instances (album name, or "Not in any Album").
    var scopeTitle: String? = nil

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
    @State private var pendingDeleteID: Int?
    @State private var showingRenameAlbum = false
    @State private var renameAlbumText = ""
    @State private var showingDeleteAlbumConfirm = false

    enum Mode: Hashable { case photos, albums }
    @State private var mode: Mode = .photos
    @State private var albumSummaries: [LibrarySortService.AlbumSummary] = []
    @State private var notInAnyAlbumCount: Int = 0
    @State private var addToAlbumRequest: AddToAlbumRequest?
    @State private var showingSortAssistant = false
    @State private var editDescriptionRequest: AlbumDescriptionSheet.Request?

    /// Identity-carrying payload for the Manage-Albums sheet. Using `.sheet(item:)`
    /// with this (instead of `.sheet(isPresented:)` + a separate `[Int]?`) makes
    /// SwiftUI rebuild the sheet's content — and re-read the current
    /// `albumSummaries` — on every presentation. The old isPresented binding could
    /// reuse stale content from an earlier presentation (e.g. an empty album list
    /// captured before the first album was created).
    struct AddToAlbumRequest: Identifiable {
        let id = UUID()
        let itemIDs: [Int]
        /// How many of `itemIDs` are in each album, captured at presentation
        /// time — seeds the sheet's tri-state checkmarks.
        let membershipCounts: [UUID: Int]
    }

    @ViewBuilder
    private var rootContent: some View {
        if filter == .all && mode == .albums {
            AlbumsBrowserView(
                summaries: albumSummaries,
                notInAnyAlbumCount: notInAnyAlbumCount,
                onNewAlbum: { presentAddToAlbum([]) }   // empty selection → create-only flow
            )
        } else {
            content(for: content)
        }
    }

    var body: some View {
        rootContent
            .navigationTitle(isSelecting ? selectionTitle : (scopeTitle ?? "Library"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { libraryToolbar }
            .confirmationDialog(
                bulkDeleteTitle,
                isPresented: $showingBulkDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    let ids = Array(selectedIDs)
                    Task {
                        await store.remove(itemIDs: ids)
                        exitSelection()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes your saved copies and their metadata from iCloud.")
            }
            .confirmationDialog(
                "Delete this item?",
                isPresented: Binding(
                    get: { pendingDeleteID != nil },
                    set: { if !$0 { pendingDeleteID = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDeleteID
            ) { itemID in
                Button("Delete", role: .destructive) {
                    Task { await store.remove(itemID: itemID) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This deletes your saved copy and its metadata from iCloud.")
            }
            .alert("Rename Album", isPresented: $showingRenameAlbum) {
                TextField("Album name", text: $renameAlbumText)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    if case .album(let albumID) = filter {
                        let name = renameAlbumText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        Task {
                            await store.albumService.renameAlbum(albumID, to: name)
                            store.notifyAlbumsChanged()
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete this album?",
                isPresented: $showingDeleteAlbumConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete Album", role: .destructive) {
                    if case .album(let albumID) = filter {
                        Task {
                            await store.albumService.deleteAlbum(albumID)
                            store.notifyAlbumsChanged()
                            dismiss()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The album is removed. Your photos and videos are kept.")
            }
            .sheet(item: $addToAlbumRequest) { request in
                ManageAlbumsSheet(
                    itemIDs: request.itemIDs,
                    summaries: albumSummaries,
                    membershipCounts: request.membershipCounts,
                    onChanged: { exitSelection() }
                )
                .environmentObject(store)
            }
            .sheet(isPresented: $showingSortAssistant) {
                SortAssistantSheet()
                    .environmentObject(store)
            }
            .sheet(item: $editDescriptionRequest) { request in
                AlbumDescriptionSheet(request: request)
                    .environmentObject(store)
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
            .onChange(of: store.albumsVersion) {
                reloadContent()
            }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .navigation) {
                Button(allSelected ? "Deselect All" : "Select All") {
                    if allSelected {
                        selectedIDs.removeAll()
                    } else {
                        selectedIDs = Set(allItemIDs)
                    }
                }
                .disabled(allItemIDs.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Done") { exitSelection() }
            }
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    showingBulkDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(selectedIDs.isEmpty)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    presentAddToAlbum(Array(selectedIDs))
                } label: { Label("Manage Albums", systemImage: "rectangle.stack") }
                .disabled(selectedIDs.isEmpty)
            }
            if case .album(let albumID) = filter {
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        let ids = Array(selectedIDs)
                        Task {
                            await store.albumService.removeItems(ids, fromAlbum: albumID)
                            store.notifyAlbumsChanged()
                            exitSelection()
                        }
                    } label: {
                        Label("Remove from Album", systemImage: "rectangle.stack.badge.minus")
                    }
                    .disabled(selectedIDs.isEmpty)
                }
            }
        } else {
            if filter == .all {
                ToolbarItem(placement: .principal) {
                    Picker("Mode", selection: $mode) {
                        Text("Photos").tag(Mode.photos)
                        Text("Albums").tag(Mode.albums)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                LibrarySortMenu(selectedSort: $selectedSort)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Select") { isSelecting = true }
                    .disabled(content.isEmpty)
            }
            if filter == .all && mode == .albums {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingSortAssistant = true
                    } label: {
                        Label("Sort Assistant", systemImage: "sparkles")
                    }
                }
            }
            if case .album = filter {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            renameAlbumText = scopeTitle ?? ""
                            showingRenameAlbum = true
                        } label: { Label("Rename Album", systemImage: "pencil") }
                        Button {
                            if case .album(let albumID) = filter {
                                presentEditDescription(albumID: albumID)
                            }
                        } label: { Label("Edit Description", systemImage: "text.quote") }
                        Button(role: .destructive) {
                            showingDeleteAlbumConfirm = true
                        } label: { Label("Delete Album", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
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
                .accessibilityLabel(item.isVideo ? "Video" : "Photo")
                .accessibilityAddTraits(selectedIDs.contains(item.itemID) ? .isSelected : [])
            } else {
                NavigationLink {
                    LibraryDetailView(itemID: item.itemID)
                } label: {
                    thumbnail(for: item)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        presentAddToAlbum([item.itemID])
                    } label: { Label("Manage Albums", systemImage: "rectangle.stack") }
                    if case .album(let albumID) = filter {
                        Button {
                            Task {
                                await store.albumService.removeItems([item.itemID], fromAlbum: albumID)
                                store.notifyAlbumsChanged()
                            }
                        } label: { Label("Remove from Album", systemImage: "rectangle.stack.badge.minus") }
                    }
                    Button(role: .destructive) {
                        pendingDeleteID = item.itemID
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
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

    // All item IDs currently shown, flattened across any sort groups.
    private var allItemIDs: [Int] {
        switch content {
        case .flat(let items):
            return items.map { $0.itemID }
        case .grouped(let groups):
            return groups.flatMap { $0.items }.map { $0.itemID }
        }
    }

    private var allSelected: Bool {
        !allItemIDs.isEmpty && selectedIDs.count == allItemIDs.count
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

    /// Reads the album's current description/profile from the index *now* and
    /// presents the edit sheet — same fresh-capture pattern as
    /// `presentAddToAlbum`.
    private func presentEditDescription(albumID: UUID) {
        var descriptor = FetchDescriptor<PersistedAlbum>(
            predicate: #Predicate { $0.id == albumID }
        )
        descriptor.fetchLimit = 1
        guard let row = try? modelContext.fetch(descriptor).first else { return }
        editDescriptionRequest = AlbumDescriptionSheet.Request(
            albumID: albumID,
            albumName: row.name,
            userDescription: row.userDescription,
            profileText: row.aiProfileText,
            profileBuiltAt: row.aiProfileBuiltAt,
            profileMemberCount: row.aiProfileMemberCount
        )
    }

    /// Recompute the album list and the selection's membership from the index
    /// *now*, then present the Manage-Albums sheet — so it always reflects the
    /// current state regardless of reload timing.
    private func presentAddToAlbum(_ ids: [Int]) {
        if let sortService {
            albumSummaries = sortService.albumSummaries()
        }
        addToAlbumRequest = AddToAlbumRequest(
            itemIDs: ids,
            membershipCounts: sortService?.albumMembershipCounts(for: ids) ?? [:]
        )
    }

    private func reloadContent() {
        guard let sortService else { return }
        let newContent = sortService.sortedLibraryContent(sort: selectedSort, filter: filter)

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

        albumSummaries = sortService.albumSummaries()
        notInAnyAlbumCount = sortService.notInAnyAlbumCount()
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

    private var selectionTitle: String {
        selectedIDs.isEmpty ? "Select Items" : "\(selectedIDs.count) Selected"
    }

    private var bulkDeleteTitle: String {
        let n = selectedIDs.count
        return "Delete \(n) item\(n == 1 ? "" : "s")?"
    }

    private func exitSelection() {
        isSelecting = false
        selectedIDs.removeAll()
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
