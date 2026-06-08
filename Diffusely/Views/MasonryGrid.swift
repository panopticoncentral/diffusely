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

    // Store the derived column count, not the raw measured width. Writing the
    // measured width into state during layout caused a feedback loop: SwiftUI's
    // multi-pass layout reports transient widths (32, 24, 402, …), each write
    // re-evaluated the body and re-ran `itemColumns` over every item, which
    // triggered another layout pass — an unbounded 100%-CPU spin on large
    // libraries. The column count only changes at coarse width thresholds, so
    // gating state on it lets transient widths collapse to a no-op.
    @State private var columnCount: Int = 3

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

    /// Distributes items across columns, appending each to the shortest column.
    /// Balancing uses `targetColumnWidth` as a stable reference rather than the
    /// measured width: the actual on-screen width is set by the HStack/LazyVStack
    /// layout, and using a constant here keeps the distribution from churning on
    /// every sub-point width change.
    private var itemColumns: [[Item]] {
        let count = columnCount
        var result = Array(repeating: [Item](), count: count)
        var heights = Array(repeating: CGFloat.zero, count: count)

        for item in items {
            let ratio = max(0.01, aspectRatio(item))
            let itemHeight = targetColumnWidth / ratio
            let shortestIndex = heights.enumerated().min(by: { $0.element < $1.element })!.offset
            result[shortestIndex].append(item)
            heights[shortestIndex] += itemHeight + spacing
        }

        return result
    }

    private func columnCount(for width: CGFloat) -> Int {
        guard width > 0 else { return 3 }
        return max(2, Int(width / targetColumnWidth))
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
            let newCount = columnCount(for: width)
            if newCount != columnCount { columnCount = newCount }
        }
    }
}
