#if os(macOS)
import SwiftUI

struct WaterfallGrid: View {
    let images: [CivitaiImage]
    let targetColumnWidth: CGFloat
    let spacing: CGFloat
    let onLastAppeared: () -> Void

    @State private var containerWidth: CGFloat = 0

    init(
        images: [CivitaiImage],
        targetColumnWidth: CGFloat = 240,
        spacing: CGFloat = 8,
        onLastAppeared: @escaping () -> Void
    ) {
        self.images = images
        self.targetColumnWidth = targetColumnWidth
        self.spacing = spacing
        self.onLastAppeared = onLastAppeared
    }

    /// Number of columns that fit the current window width, scaling with resize.
    private var columnCount: Int {
        guard containerWidth > 0 else { return 3 }
        return max(2, Int(containerWidth / targetColumnWidth))
    }

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<columnCount, id: \.self) { columnIndex in
                LazyVStack(spacing: spacing) {
                    ForEach(columns[columnIndex]) { image in
                        ImageFeedItemView(image: image, isGridMode: true, preserveAspectRatio: true)
                            .onAppear {
                                if image.id == images.last?.id {
                                    onLastAppeared()
                                }
                            }
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

    /// Distributes images across columns, placing each image in the shortest column
    private var columns: [[CivitaiImage]] {
        var result = Array(repeating: [CivitaiImage](), count: columnCount)
        var heights = Array(repeating: CGFloat.zero, count: columnCount)

        let totalSpacing = spacing * CGFloat(columnCount - 1) + spacing * 2
        let columnWidth = max(1, (containerWidth - totalSpacing) / CGFloat(columnCount))

        for image in images {
            let aspectRatio = CGFloat(image.width) / max(1, CGFloat(image.height))
            let itemHeight = columnWidth / aspectRatio

            // Place in shortest column
            let shortestIndex = heights.enumerated().min(by: { $0.element < $1.element })!.offset
            result[shortestIndex].append(image)
            heights[shortestIndex] += itemHeight + spacing
        }

        return result
    }
}
#endif
