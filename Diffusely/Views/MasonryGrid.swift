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
    private let onActivate: ((Item) -> Void)?
    private let onFocus: (Item.ID) -> Void
    @State private var focusedIndex: Int?
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
        spacing: CGFloat = AppUI.gridSpacing,
        aspectRatio: @escaping (Item) -> CGFloat,
        onActivate: ((Item) -> Void)? = nil,
        onFocus: @escaping (Item.ID) -> Void = { _ in },
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.onActivate = onActivate
        self.onFocus = onFocus
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
                            .id(item.id)
                            #if os(macOS)
                            .overlay {
                                if let focusedIndex, items.indices.contains(focusedIndex), items[focusedIndex].id == item.id {
                                    RoundedRectangle(cornerRadius: AppUI.cornerRadius).strokeBorder(Color.accentColor, lineWidth: 3)
                                }
                            }
                            #endif
                    }
                }
            }
        }
        #if os(macOS)
        .gridKeyboardNavigation(count: onActivate == nil ? 0 : items.count, columns: columnCount,
                                focusedIndex: $focusedIndex, onActivate: { index in
            guard items.indices.contains(index) else { return }
            onActivate?(items[index])
        }, autoFocus: false, destination: keyboardDestination)
        .onChange(of: focusedIndex) {
            if let focusedIndex, items.indices.contains(focusedIndex) { onFocus(items[focusedIndex].id) }
        }
        .onChange(of: items.map(\.id)) { old, new in
            if let focusedIndex, old.indices.contains(focusedIndex) {
                self.focusedIndex = new.firstIndex(of: old[focusedIndex])
            }
        }
        #endif
        .padding(.horizontal, spacing)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            let newCount = columnCount(for: width)
            if newCount != columnCount { columnCount = newCount }
        }
    }
    #if os(macOS)
    private func keyboardDestination(_ index: Int, _ direction: MoveCommandDirection) -> Int? {
        guard items.indices.contains(index) else { return nil }
        let indices = Dictionary(items.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var frames: [Int: CGRect] = [:]
        for (column, entries) in itemColumns.enumerated() {
            var y: CGFloat = 0
            for item in entries {
                let height = targetColumnWidth / max(0.01, aspectRatio(item))
                if let index = indices[item.id] {
                    frames[index] = CGRect(x: CGFloat(column) * (targetColumnWidth + spacing), y: y,
                                           width: targetColumnWidth, height: height)
                }
                y += height + spacing
            }
        }
        guard let current = frames[index] else { return nil }
        return frames.filter { candidate in
            let frame = candidate.value
            switch direction {
            case .up: return frame.minX == current.minX && frame.midY < current.midY
            case .down: return frame.minX == current.minX && frame.midY > current.midY
            case .left: return frame.minX < current.minX
            case .right: return frame.minX > current.minX
            @unknown default: return false
            }
        }.min { a, b in
            func distance(_ frame: CGRect) -> CGFloat {
                abs(frame.midX - current.midX) * 4 + abs(frame.midY - current.midY)
            }
            return distance(a.value) < distance(b.value)
        }?.key
    }
    #endif

}
