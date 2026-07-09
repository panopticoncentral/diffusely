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

    /// Live album name for scoped instances. Seeded from `scopeTitle` on first
    /// appearance and updated in place after a rename, so the navigation title
    /// and the rename alert's seed text reflect the new name immediately instead
    /// of the value captured when the view was pushed.
    @State private var currentScopeTitle: String? = nil

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
    @State private var renameAlbumText = ""
    /// Target for the rename alert / delete confirmation. Set from either the
    /// scoped album's ellipsis menu or an album tile's context menu in the
    /// browser, so both entry points drive the same alert and dialog.
    @State private var renameAlbumTarget: AlbumRef?
    @State private var deleteAlbumTarget: AlbumRef?

    enum Mode: Hashable { case photos, albums }
    @State private var mode: Mode = .photos
    /// Coalesces reload triggers: `selectedSort`, `store.itemCount`, and
    /// `store.albumsVersion` can all change in the same update (e.g. after a
    /// reconcile), and each reload is a full SwiftData scan. Collapse the burst
    /// into one reload on the next runloop tick.
    @State private var reloadScheduled = false
    @State private var albumSummaries: [LibrarySortService.AlbumSummary] = []
    @State private var notInAnyAlbumCount: Int = 0
    @State private var addToAlbumRequest: AddToAlbumRequest?
    @State private var showingSortAssistant = false
    @State private var editDescriptionRequest: AlbumDescriptionSheet.Request?
    #if os(iOS)
    @State private var showingSettings = false
    #endif

    #if os(macOS)
    /// Roaming keyboard focus over the flat photo grid: index into `orderedItems`.
    @State private var focusedIndex: Int?
    /// Set by Return to push the focused item's detail view.
    @State private var keyboardOpenItem: FocusedItem?
    /// Files handed to `QuickLookHost` when Space previews the focused item.
    @State private var quickLookURLs: [URL] = []
    @State private var quickLookPresented = false

    struct FocusedItem: Identifiable, Hashable { let id: Int }
    #endif

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

    /// Which album a rename/delete action targets. `id` doubles as the
    /// `Identifiable` key so the confirmation dialog can present it directly.
    struct AlbumRef: Identifiable {
        let id: UUID
        let name: String
    }

    /// The album name to display: the live, rename-aware value once seeded,
    /// falling back to the value passed in at push time.
    private var resolvedScopeTitle: String? {
        currentScopeTitle ?? scopeTitle
    }

    /// Optional-backed presentation bindings for the rename alert and delete
    /// dialog. Extracted from the body's modifier chain so the SwiftUI
    /// type-checker doesn't time out on the already-long expression.
    private var renameAlbumPresented: Binding<Bool> {
        Binding(get: { renameAlbumTarget != nil }, set: { if !$0 { renameAlbumTarget = nil } })
    }
    private var deleteAlbumPresented: Binding<Bool> {
        Binding(get: { deleteAlbumTarget != nil }, set: { if !$0 { deleteAlbumTarget = nil } })
    }

    /// True when the top-level Library is showing the Albums browser rather than
    /// the photo grid. Selection, sorting, and bulk actions all operate on the
    /// (hidden) photo content, so they must not be offered here.
    private var isAlbumsMode: Bool {
        filter == .all && mode == .albums
    }

    @ViewBuilder
    private var rootContent: some View {
        if filter == .all && mode == .albums {
            AlbumsBrowserView(
                summaries: albumSummaries,
                notInAnyAlbumCount: notInAnyAlbumCount,
                onNewAlbum: { presentAddToAlbum([]) },   // empty selection → create-only flow
                onRenameAlbum: { beginRenameAlbum(id: $0.id, name: $0.name) },
                onEditAlbumDescription: { presentEditDescription(albumID: $0) },
                onDeleteAlbum: { deleteAlbumTarget = AlbumRef(id: $0.id, name: $0.name) },
                onDropItems: { itemIDs, albumID in
                    Task {
                        await store.albumService.addItems(itemIDs, toAlbum: albumID)
                        store.notifyAlbumsChanged()
                    }
                }
            )
        } else {
            content(for: content)
        }
    }

    var body: some View {
        rootContent
            .navigationTitle(isSelecting ? selectionTitle : (resolvedScopeTitle ?? "Library"))
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
            .alert("Rename Album", isPresented: renameAlbumPresented) {
                TextField("Album name", text: $renameAlbumText)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    guard let target = renameAlbumTarget else { return }
                    let name = renameAlbumText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    Task {
                        await store.albumService.renameAlbum(target.id, to: name)
                        store.notifyAlbumsChanged()
                        // Keep the navigation title live if we're renaming the
                        // album this scoped instance is currently showing.
                        if case .album(let scopedID) = filter, scopedID == target.id {
                            currentScopeTitle = name
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete this album?",
                isPresented: deleteAlbumPresented,
                titleVisibility: .visible,
                presenting: deleteAlbumTarget
            ) { target in
                Button("Delete Album", role: .destructive) {
                    Task {
                        await store.albumService.deleteAlbum(target.id)
                        store.notifyAlbumsChanged()
                        // Only pop when we're deleting the album we're inside;
                        // deleting from the browser just refreshes the grid.
                        if case .album(let scopedID) = filter, scopedID == target.id {
                            dismiss()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
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
            #if os(iOS)
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            #endif
            .task {
                if currentScopeTitle == nil { currentScopeTitle = scopeTitle }
                store.start()
                initializeServices()
                reloadContent()
                await maybeStartBackfill()
            }
            .onChange(of: selectedSort) {
                scheduleReload()
                Task { await maybeStartBackfill() }
            }
            .onChange(of: store.itemCount) {
                scheduleReload()
            }
            .onChange(of: store.albumsVersion) {
                scheduleReload()
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
                // ⌘A toggles select-all while in selection mode (only present
                // then, so it never shadows text Select All elsewhere).
                .keyboardShortcut("a", modifiers: .command)
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
                // Delete key removes the current selection (disabled → no-op
                // when nothing is selected).
                .keyboardShortcut(.delete, modifiers: [])
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
            #if os(iOS)
            // iOS reaches Settings from each feed's toolbar gear; the Library
            // tab needs its own (macOS uses the app menu ▸ Settings).
            if filter == .all {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                }
            }
            #endif
            // Sort and Select act on the photo grid. In Albums mode that grid is
            // hidden behind the album browser, so offering them there would sort
            // or select content the user can't see (Select All + delete could
            // then bulk-remove invisible items). Hide both in Albums mode.
            if !isAlbumsMode {
                ToolbarItem(placement: .primaryAction) {
                    LibrarySortMenu(selectedSort: $selectedSort)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Select") { isSelecting = true }
                        .disabled(content.isEmpty)
                }
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
                            if case .album(let albumID) = filter {
                                beginRenameAlbum(id: albumID, name: resolvedScopeTitle ?? "")
                            }
                        } label: { Label("Rename Album", systemImage: "pencil") }
                        Button {
                            if case .album(let albumID) = filter {
                                presentEditDescription(albumID: albumID)
                            }
                        } label: { Label("Edit Description", systemImage: "text.quote") }
                        Button(role: .destructive) {
                            if case .album(let albumID) = filter {
                                deleteAlbumTarget = AlbumRef(id: albumID, name: resolvedScopeTitle ?? "")
                            }
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
            ScrollViewReader { proxy in
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
                #if os(macOS)
                // Keyboard focus + Return-to-open + Space→Quick Look, but only
                // for the flat grid: collapsed sections make a roaming focus
                // index unreliable, so grouped sorts keep click-only behavior.
                .gridKeyboardNavigation(
                    count: navigableItemCount(for: content),
                    columns: gridColumnCount,
                    focusedIndex: $focusedIndex,
                    onActivate: { openFocusedItem($0) },
                    onQuickLook: { quickLookFocusedItem($0) }
                )
                .onChange(of: focusedIndex) { scrollFocusedItemIntoView(using: proxy) }
                .navigationDestination(item: $keyboardOpenItem) { LibraryDetailView(itemID: $0.id) }
                .background {
                    QuickLookHost(urls: quickLookURLs, isPresented: $quickLookPresented) {
                        quickLookPresented = false
                    }
                }
                #endif
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
                #if os(macOS)
                // Drag a saved item out to Finder / Photos / other apps. iOS is
                // omitted: there, drag start (long-press) fights the cell's
                // context menu and navigation gestures.
                .draggable(LibraryItemTransfer(itemID: item.itemID, mediaFileName: item.mediaFileName))
                .overlay {
                    if item.itemID == focusedItemID {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
                #endif
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

    #if os(macOS)
    // MARK: - Keyboard focus (flat grid)

    /// The photo items in display order — the sequence keyboard focus walks.
    private var orderedItems: [PersistedLibraryItem] {
        switch content {
        case .flat(let items): return items
        case .grouped(let groups): return groups.flatMap { $0.items }
        }
    }

    /// itemID of the keyboard-focused cell, for drawing its ring. Nil unless a
    /// flat grid is showing and an index is set.
    private var focusedItemID: Int? {
        guard let focusedIndex, orderedItems.indices.contains(focusedIndex) else { return nil }
        return orderedItems[focusedIndex].itemID
    }

    /// Keyboard nav is offered only for the flat grid (see `content(for:)`).
    private func navigableItemCount(for content: LibrarySortService.LibrarySortedContent) -> Int {
        if case .flat(let items) = content { return items.count }
        return 0
    }

    private func openFocusedItem(_ index: Int) {
        guard orderedItems.indices.contains(index) else { return }
        keyboardOpenItem = FocusedItem(id: orderedItems[index].itemID)
    }

    private func quickLookFocusedItem(_ index: Int) {
        guard orderedItems.indices.contains(index) else { return }
        let item = orderedItems[index]
        Task {
            guard let dir = try? await LibraryContainer.shared.itemsDirectory() else { return }
            quickLookURLs = [dir.appendingPathComponent(item.mediaFileName)]
            quickLookPresented = true
        }
    }

    /// Keeps the focused cell on screen. Scrolls by the ForEach identity
    /// (the model id), which is what `ScrollView` tracks.
    private func scrollFocusedItemIntoView(using proxy: ScrollViewProxy) {
        guard let focusedIndex, orderedItems.indices.contains(focusedIndex) else { return }
        proxy.scrollTo(orderedItems[focusedIndex].id, anchor: .center)
    }
    #endif

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

    /// Seeds the rename field and arms the rename alert for the given album.
    /// Shared by the scoped ellipsis menu and the browser tile context menu.
    private func beginRenameAlbum(id: UUID, name: String) {
        renameAlbumText = name
        renameAlbumTarget = AlbumRef(id: id, name: name)
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

    /// Defer a reload to the next runloop tick, collapsing multiple triggers
    /// fired within the same update into a single `reloadContent()`.
    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        Task { @MainActor in
            reloadScheduled = false
            reloadContent()
        }
    }

    private func reloadContent() {
        guard let sortService else { return }
        // One fetch for content + album summaries + the not-in-any-album count,
        // instead of three separate full-table fetches on the main thread.
        let bundle = sortService.libraryContent(sort: selectedSort, filter: filter)
        let newContent = bundle.content

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
        albumSummaries = bundle.albumSummaries
        notInAnyAlbumCount = bundle.notInAnyAlbumCount
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
