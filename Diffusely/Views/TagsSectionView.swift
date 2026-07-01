import SwiftUI

/// The "Tags" section on the image/video detail view: tappable tag chips,
/// collapsed to `collapsedCount` with a "Show more" toggle. Empty handling is
/// the caller's job (it omits this view entirely when there are no tags).
struct TagsSectionView: View {
    let tags: [CivitaiVotableTag]
    @Binding var showAll: Bool
    let onSelect: (CivitaiVotableTag) -> Void

    private let collapsedCount = 6

    private var visibleTags: [CivitaiVotableTag] {
        if showAll || tags.count <= collapsedCount {
            return tags
        }
        return Array(tags.prefix(collapsedCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags")
                .font(.headline)
                .foregroundColor(.primary)

            FlowLayout(spacing: 8) {
                ForEach(visibleTags) { tag in
                    Button {
                        onSelect(tag)
                    } label: {
                        Text(tag.name)
                            .font(.caption)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                            .background(Color(.secondarySystemBackground))
                            .foregroundColor(.primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            if tags.count > collapsedCount {
                Button {
                    withAnimation { showAll.toggle() }
                } label: {
                    Text(showAll ? "Show less" : "Show more")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A simple wrapping flow layout: places subviews left-to-right, wrapping to a
/// new row when the current row runs out of width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        Self.flowSize(
            subviewSizes: subviews.map { $0.sizeThatFits(.unspecified) },
            proposedWidth: proposal.width,
            spacing: spacing
        )
    }

    /// Computes the flow-layout bounding size for `subviewSizes`, wrapping within
    /// `proposedWidth`. Pure (no SwiftUI types) so it is unit-testable.
    ///
    /// The returned width MUST be finite. SwiftUI probes a view's size range by
    /// proposing `nil` (unspecified) and `.infinity` widths; if we propagate a
    /// non-finite width back, SwiftUI hands AppKit an invalid frame that it
    /// rejects mid-layout (throwing inside `-[NSView _layoutSubtreeWithOldSize:]`),
    /// which on macOS pins the main thread at 100% CPU in an endless re-layout
    /// loop (beachball).
    static func flowSize(subviewSizes: [CGSize], proposedWidth: CGFloat?, spacing: CGFloat) -> CGSize {
        let maxWidth = proposedWidth ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for size in subviewSizes {
            if rowWidth + size.width > maxWidth && rowWidth > 0 {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth - spacing)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth - spacing)

        // Never return a non-finite width: when the proposal is unspecified or
        // infinite, report the intrinsic content width instead of `.infinity`.
        let resolvedWidth = maxWidth.isFinite ? maxWidth : totalWidth
        return CGSize(width: resolvedWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
