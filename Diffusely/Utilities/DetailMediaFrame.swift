import SwiftUI

extension View {
    /// Sizes detail-view media to fill width, and on macOS also caps height to
    /// the given value so the whole image/video fits the visible window.
    func detailMediaFrame(maxHeight: CGFloat) -> some View {
        #if os(macOS)
        return self.frame(maxWidth: .infinity, maxHeight: maxHeight)
        #else
        return self.frame(maxWidth: .infinity)
        #endif
    }
}
