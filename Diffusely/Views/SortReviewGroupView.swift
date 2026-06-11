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

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]

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
        .toolbar {
            if isActionable {
                ToolbarItem(placement: .primaryAction) {
                    Button("Accept (\(selectedIDs.count))") {
                        isAccepting = true
                        Task {
                            await service.accept(group: group, selectedIDs: selectedIDs)
                            store.notifyAlbumsChanged()
                            dismiss()
                        }
                    }
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
            let ids = Set(group.entries.map(\.itemID))
            let all = (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
            itemsByID = Dictionary(
                all.filter { ids.contains($0.itemID) }.map { ($0.itemID, $0) },
                uniquingKeysWith: { a, _ in a })
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
            .accessibilityLabel(item.isVideo ? "Video" : "Photo")
            .accessibilityAddTraits(isActionable ? .isButton : [])
            .accessibilityAddTraits(isActionable && isSelected ? .isSelected : [])
    }
}
