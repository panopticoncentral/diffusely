import SwiftUI

/// Pinch/magnify-to-zoom with drag-to-pan for still images in the detail
/// views. Double-tap (double-click on macOS) toggles between fit and 2.5×.
///
/// The pan gesture is attached only while zoomed in (and as high priority) so
/// it wins over the enclosing pager/scroll view then, but never interferes
/// with normal page swiping or scrolling at 1×. Scale and offset snap back to
/// identity when a gesture would leave the content smaller than fit.
struct ZoomableView<Content: View>: View {
    @ViewBuilder var content: () -> Content

    private static var maxScale: CGFloat { 5 }
    private static var doubleTapScale: CGFloat { 2.5 }

    @State private var scale: CGFloat = 1
    @State private var gestureScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var gestureOffset: CGSize = .zero

    private var effectiveScale: CGFloat { scale * gestureScale }
    private var effectiveOffset: CGSize {
        CGSize(width: offset.width + gestureOffset.width,
               height: offset.height + gestureOffset.height)
    }

    var body: some View {
        GeometryReader { geometry in
            content()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(effectiveScale)
                .offset(effectiveOffset)
                .gesture(magnifyGesture(in: geometry.size))
                .highPriorityGesture(effectiveScale > 1.01 ? panGesture(in: geometry.size) : nil)
                .onTapGesture(count: 2) { toggleZoom() }
                .animation(.easeOut(duration: 0.2), value: scale)
                .animation(.easeOut(duration: 0.2), value: offset)
        }
        // Zoomed content must not bleed over neighboring carousel pages or the
        // metadata below the media.
        .clipped()
        .contentShape(Rectangle())
    }

    private func magnifyGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                gestureScale = value.magnification
            }
            .onEnded { value in
                scale = min(Self.maxScale, max(1, scale * value.magnification))
                gestureScale = 1
                if scale <= 1.01 {
                    reset()
                } else {
                    offset = clampedOffset(offset, in: size)
                }
            }
    }

    private func panGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                gestureOffset = value.translation
            }
            .onEnded { value in
                offset = clampedOffset(
                    CGSize(width: offset.width + value.translation.width,
                           height: offset.height + value.translation.height),
                    in: size
                )
                gestureOffset = .zero
            }
    }

    private func toggleZoom() {
        if scale > 1.01 {
            reset()
        } else {
            scale = Self.doubleTapScale
        }
    }

    private func reset() {
        scale = 1
        offset = .zero
        gestureScale = 1
        gestureOffset = .zero
    }

    /// Keeps the pan within the scaled content's bounds so the image can't be
    /// dragged fully off screen. The content fits the frame at 1×, so the
    /// reachable overflow on each axis is (scale − 1) × dimension / 2.
    private func clampedOffset(_ proposed: CGSize, in size: CGSize) -> CGSize {
        let maxX = size.width * (scale - 1) / 2
        let maxY = size.height * (scale - 1) / 2
        return CGSize(
            width: min(maxX, max(-maxX, proposed.width)),
            height: min(maxY, max(-maxY, proposed.height))
        )
    }
}
