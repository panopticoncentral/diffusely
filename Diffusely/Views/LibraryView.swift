import SwiftUI
import SwiftData

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @Query(sort: \PersistedLibraryItem.savedAt, order: .reverse)
    private var items: [PersistedLibraryItem]

    // Photos-style masonry: equal-width columns, each image at its natural
    // aspect ratio, even whitespace between and around images.
    private let spacing: CGFloat = 6
    private let targetColumnWidth: CGFloat = 130

    @State private var containerWidth: CGFloat = 0

    private var columnCount: Int {
        guard containerWidth > 0 else { return 3 }
        return max(2, Int(containerWidth / targetColumnWidth))
    }

    /// Distributes items across columns, appending each to the shortest column.
    private var itemColumns: [[PersistedLibraryItem]] {
        let count = columnCount
        var result = Array(repeating: [PersistedLibraryItem](), count: count)
        var heights = Array(repeating: CGFloat.zero, count: count)

        let totalSpacing = spacing * CGFloat(count - 1) + spacing * 2
        let columnWidth = max(1, (containerWidth - totalSpacing) / CGFloat(count))

        for item in items {
            let aspectRatio = CGFloat(item.width) / max(1, CGFloat(item.height))
            let itemHeight = columnWidth / aspectRatio
            let shortestIndex = heights.enumerated().min(by: { $0.element < $1.element })!.offset
            result[shortestIndex].append(item)
            heights[shortestIndex] += itemHeight + spacing
        }

        return result
    }

    var body: some View {
        content
            .navigationTitle("Library")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onAppear { store.start() }
    }

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            emptyState
        } else {
            ScrollView {
                if !store.isICloudBacked {
                    localOnlyBanner
                }
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(0..<columnCount, id: \.self) { columnIndex in
                        LazyVStack(spacing: spacing) {
                            ForEach(itemColumns[columnIndex]) { item in
                                NavigationLink {
                                    LibraryDetailView(itemID: item.itemID)
                                } label: {
                                    thumbnail(for: item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, spacing)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    containerWidth = width
                }

                Text(itemCountText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .background(Color(.systemBackground))
        }
    }

    private var itemCountText: String {
        let videos = items.filter { $0.isVideo }.count
        let photos = items.count - videos
        var parts: [String] = []
        if photos > 0 { parts.append("\(photos) Photo\(photos == 1 ? "" : "s")") }
        if videos > 0 { parts.append("\(videos) Video\(videos == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    private func thumbnail(for item: PersistedLibraryItem) -> some View {
        Color(.secondarySystemBackground)
            .aspectRatio(CGFloat(item.width) / max(1, CGFloat(item.height)), contentMode: .fit)
            .overlay {
                LibraryAsyncImage(
                    itemID: item.itemID,
                    mediaFileName: item.mediaFileName,
                    maxDimension: 600,
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
            if !store.isICloudBacked {
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
}
