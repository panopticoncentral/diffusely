import SwiftUI

enum DetailMediaFrame {
    /// The height cap to hand SwiftUI for detail media, or `nil` for no cap.
    ///
    /// The caller reads this from a `GeometryReader`, which proposes 0 on the
    /// first layout pass. Capping to 0 (or to a non-finite value, should a
    /// container ever propose one) would collapse the media to nothing, so
    /// those cases fall back to an uncapped frame and settle on the next pass.
    static func heightCap(available: CGFloat) -> CGFloat? {
        guard available.isFinite, available > 0 else { return nil }
        return available
    }

    /// Band height for the paged carousel on iOS, where the page dots sit in a
    /// row below the media (on macOS they float over it, so the band there just
    /// takes the full height). Reserving the dots' row keeps the media *and*
    /// its dots inside the display area.
    ///
    /// Unlike `heightCap` this always answers a usable number: the band is an
    /// exact frame around a `GeometryReader`, which has no intrinsic size, so
    /// leaving it unconstrained would collapse the carousel to nothing.
    static func carouselHeight(available: CGFloat, indicatorHeight: CGFloat) -> CGFloat {
        guard let usable = heightCap(available: available) else { return carouselFallbackHeight }
        return max(1, usable - indicatorHeight)
    }

    /// Band height to use until the enclosing geometry has been measured.
    static let carouselFallbackHeight: CGFloat = 500
}

extension View {
    /// Sizes detail-view media to fill width and caps its height to the visible
    /// area, so the whole image/video fits without scrolling. The cap matters
    /// wherever the view is wide relative to its height — a full-width portrait
    /// image on an iPad or a Mac window runs well past the bottom of the screen
    /// without it. On a phone the media is usually shorter than the cap anyway,
    /// so this leaves it unchanged.
    func detailMediaFrame(maxHeight: CGFloat) -> some View {
        frame(maxWidth: .infinity, maxHeight: DetailMediaFrame.heightCap(available: maxHeight))
    }
}
