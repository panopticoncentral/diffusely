import SwiftUI
import SwiftData

/// One review group: a grid of suggested items (confidence-ordered, all
/// pre-selected). Deselect the misses, Accept writes membership and records
/// rejections. Long-press opens the full Manage Albums sheet for an item.
struct SortReviewGroupView: View {
    let group: SortAssistant.ReviewGroup
    @ObservedObject var service: SortAssistantService
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var selectedIDs: Set<Int> = []
    @State private var itemsByID: [Int: PersistedLibraryItem] = [:]
    @State private var isAccepting = false
    @State private var manageRequest: LibraryView.AddToAlbumRequest?
    /// Item shown in the full-size inspection overlay (magnifier button).
    @State private var previewItem: PersistedLibraryItem?

    #if os(macOS)
    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 8)]
    #else
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8)]
    #endif

    /// Unmatched / Couldn't-classify groups are informational only.
    private var isActionable: Bool {
        switch group.kind {
        case .album, .newAlbum: return true
        case .unmatched, .promptless: return false
        }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(group.entries, id: \.itemID) { entry in
                    if let item = itemsByID[entry.itemID] {
                        tile(for: item)
                    }
                }
            }
            .padding(12)
        }
        .navigationTitle(group.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay {
            if let item = previewItem {
                previewOverlay(item)
            }
        }
        // The commit action lives in an always-visible bottom bar — toolbar
        // items on views pushed inside a sheet are unreliable on macOS, and an
        // invisible Accept means reviews silently do nothing (going Back
        // intentionally discards the selection).
        .safeAreaInset(edge: .bottom) {
            if isActionable {
                HStack {
                    Text("\(selectedIDs.count) of \(group.entries.count) selected")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(acceptTitle) { acceptSelection() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isAccepting)
                }
                .padding(12)
                .background(.bar)
            }
        }
        .toolbar {
            if isActionable {
                ToolbarItem(placement: .primaryAction) {
                    Button("Accept (\(selectedIDs.count))") { acceptSelection() }
                        .disabled(isAccepting)
                }
            }
        }
        .sheet(item: $manageRequest) { request in
            ManageAlbumsSheet(
                itemIDs: request.itemIDs,
                summaries: LibrarySortService(modelContext: modelContext).albumSummaries(),
                membershipCounts: request.membershipCounts,
                onChanged: {})
                .environmentObject(store)
        }
        .task {
            selectedIDs = Set(group.entries.map(\.itemID))
            // Predicate fetch so SQLite returns just this group's rows — a
            // full-table fetch on the main context stalls visibly (beachball)
            // at multi-thousand-item library sizes.
            let ids = group.entries.map(\.itemID)
            let descriptor = FetchDescriptor<PersistedLibraryItem>(
                predicate: #Predicate { ids.contains($0.itemID) }
            )
            let rows = (try? modelContext.fetch(descriptor)) ?? []
            itemsByID = Dictionary(
                rows.map { ($0.itemID, $0) },
                uniquingKeysWith: { a, _ in a })
        }
    }

    /// Bottom-bar label spelling out exactly what Accept will do.
    private var acceptTitle: String {
        let count = selectedIDs.count
        switch group.kind {
        case .album(_, let name):
            return count == 0 ? "Reject All" : "Add \(count) to \(name)"
        case .newAlbum(let name):
            return count == 0 ? "Reject All" : "Create \"\(name)\" & Add \(count)"
        case .unmatched, .promptless:
            return ""
        }
    }

    private func acceptSelection() {
        isAccepting = true
        Task {
            await service.accept(group: group, selectedIDs: selectedIDs)
            store.notifyAlbumsChanged()
            dismiss()
        }
    }

    private func tile(for item: PersistedLibraryItem) -> some View {
        let isSelected = selectedIDs.contains(item.itemID)
        return Color(.secondarySystemBackground)
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                LibraryAsyncImage(
                    itemID: item.itemID,
                    mediaFileName: item.mediaFileName,
                    isVideo: item.isVideo,
                    maxDimension: LibraryImageRequest.gridDimension,
                    contentMode: .fill)
            }
            .clipped()
            .overlay {
                if isActionable && !isSelected {
                    Color.black.opacity(0.35)   // dim the deselected
                }
            }
            .overlay(alignment: .topTrailing) {
                if isActionable {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? Color.accentColor : Color.white.opacity(0.6))
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard isActionable else { return }
                if isSelected {
                    selectedIDs.remove(item.itemID)
                } else {
                    selectedIDs.insert(item.itemID)
                }
            }
            .onLongPressGesture {
                manageRequest = LibraryView.AddToAlbumRequest(
                    itemIDs: [item.itemID],
                    membershipCounts: LibrarySortService(modelContext: modelContext)
                        .albumMembershipCounts(for: [item.itemID]))
            }
            .overlay(alignment: .bottomTrailing) {
                // Inspect at full size — grid tiles are too small to judge
                // borderline suggestions. A separate button (not double-click)
                // so selection taps stay instant.
                Button {
                    previewItem = item
                } label: {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.45))
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Preview")
            }
            .accessibilityLabel(item.isVideo ? "Video" : "Photo")
            .accessibilityAddTraits(isActionable ? .isButton : [])
            .accessibilityAddTraits(isActionable && isSelected ? .isSelected : [])
    }

    /// Full-size inspection overlay: image at detail resolution with a clear
    /// top bar — a ✕ close button (top-leading) and, for actionable groups, a
    /// checkmark toggle (top-trailing) mirroring the grid's selection indicator
    /// so a verdict can be made right here. Click the backdrop or press Esc
    /// (macOS) to dismiss.
    private func previewOverlay(_ item: PersistedLibraryItem) -> some View {
        let isSelected = selectedIDs.contains(item.itemID)
        return ZStack {
            Color.black.opacity(0.88)
                .contentShape(Rectangle())
                .onTapGesture { previewItem = nil }

            LibraryAsyncImage(
                itemID: item.itemID,
                mediaFileName: item.mediaFileName,
                isVideo: item.isVideo,
                maxDimension: 1600,
                contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 64)   // clear the top bar
                .padding(.bottom, 20)
        }
        .overlay(alignment: .topLeading) {
            Button { previewItem = nil } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .white.opacity(0.25))
                    .shadow(color: .black.opacity(0.5), radius: 2)
            }
            .buttonStyle(.plain)
            .padding(20)
            .accessibilityLabel("Close")
        }
        .overlay(alignment: .topTrailing) {
            if isActionable {
                Button {
                    if isSelected {
                        selectedIDs.remove(item.itemID)
                    } else {
                        selectedIDs.insert(item.itemID)
                    }
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? Color.accentColor : Color.white.opacity(0.6))
                        .shadow(color: .black.opacity(0.5), radius: 2)
                }
                .buttonStyle(.plain)
                .padding(20)
                .accessibilityLabel(isSelected ? "Deselect" : "Select")
            }
        }
        #if os(macOS)
        .onExitCommand { previewItem = nil }
        #endif
    }
}
