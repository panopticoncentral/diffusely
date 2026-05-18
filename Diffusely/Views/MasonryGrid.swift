import SwiftUI

/// Photos-style masonry: equal-width columns, each cell at its item's natural
/// aspect ratio, even whitespace between and around items. Distributes items by
/// appending each to the currently shortest column. Shared by the feed,
/// collections, and the Library.
struct MasonryGrid<Item: Identifiable, Content: View>: View {
    private let items: [Item]
    private let aspectRatio: (Item) -> CGFloat
    private let targetColumnWidth: CGFloat
    private let spacing: CGFloat
    private let content: (Item) -> Content

    @State private var containerWidth: CGFloat = 0

    init(
        items: [Item],
        targetColumnWidth: CGFloat = 240,
        spacing: CGFloat = 8,
        aspectRatio: @escaping (Item) -> CGFloat,
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.items = items
        self.aspectRatio = aspectRatio
        self.targetColumnWidth = targetColumnWidth
        self.spacing = spacing
        self.content = content
    }

    private var columnCount: Int {
        guard containerWidth > 0 else { return 3 }
        return max(2, Int(containerWidth / targetColumnWidth))
    }

    /// Distributes items across columns, appending each to the shortest column.
    private var itemColumns: [[Item]] {
        let count = columnCount
        var result = Array(repeating: [Item](), count: count)
        var heights = Array(repeating: CGFloat.zero, count: count)

        let totalSpacing = spacing * CGFloat(count - 1) + spacing * 2
        let columnWidth = max(1, (containerWidth - totalSpacing) / CGFloat(count))

        for item in items {
            let ratio = max(0.01, aspectRatio(item))
            let itemHeight = columnWidth / ratio
            let shortestIndex = heights.enumerated().min(by: { $0.element < $1.element })!.offset
            result[shortestIndex].append(item)
            heights[shortestIndex] += itemHeight + spacing
        }

        return result
    }

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<columnCount, id: \.self) { columnIndex in
                LazyVStack(spacing: spacing) {
                    ForEach(itemColumns[columnIndex]) { item in
                        content(item)
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
    }
}
