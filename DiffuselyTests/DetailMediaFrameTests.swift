import Testing
import CoreGraphics
@testable import Diffusely

/// Detail media is capped to the visible height so the whole image/video fits
/// the display area. The cap comes from a `GeometryReader`, which proposes 0 on
/// the first layout pass (and could hand us a non-finite value if a container
/// ever proposes one) — capping to that would collapse the media to nothing, so
/// those cases must fall back to an uncapped frame rather than a bad number.
@Suite struct DetailMediaFrameTests {
    @Test func usableHeightIsUsedAsTheCap() {
        #expect(DetailMediaFrame.heightCap(available: 1190) == 1190)
    }

    @Test func zeroHeightDoesNotCap() {
        #expect(DetailMediaFrame.heightCap(available: 0) == nil)
    }

    @Test func negativeHeightDoesNotCap() {
        #expect(DetailMediaFrame.heightCap(available: -10) == nil)
    }

    @Test func infiniteHeightDoesNotCap() {
        #expect(DetailMediaFrame.heightCap(available: .infinity) == nil)
    }

    @Test func nanHeightDoesNotCap() {
        #expect(DetailMediaFrame.heightCap(available: .nan) == nil)
    }
}

/// The paged carousel puts its page dots in a row *below* the media on iOS, so
/// its media band is the viewport height less that row — otherwise the dots
/// push the bottom of the media off screen. Before the geometry is known there
/// is nothing to subtract from, so it falls back to a fixed band rather than
/// collapsing (the band is an exact frame around a `GeometryReader`, which has
/// no intrinsic size of its own).
@Suite struct DetailMediaCarouselHeightTests {
    @Test func bandLeavesRoomForTheIndicatorRow() {
        #expect(DetailMediaFrame.carouselHeight(available: 1190, indicatorHeight: 38) == 1152)
    }

    @Test func singleImageCarouselHidesItsDotsAndKeepsTheirRoom() {
        #expect(DetailMediaFrame.carouselHeight(available: 1190, indicatorHeight: 0) == 1190)
    }

    @Test func unknownHeightFallsBackToAVisibleBand() {
        #expect(DetailMediaFrame.carouselHeight(available: 0, indicatorHeight: 38)
                == DetailMediaFrame.carouselFallbackHeight)
        #expect(DetailMediaFrame.carouselHeight(available: .nan, indicatorHeight: 38)
                == DetailMediaFrame.carouselFallbackHeight)
        #expect(DetailMediaFrame.carouselHeight(available: .infinity, indicatorHeight: 38)
                == DetailMediaFrame.carouselFallbackHeight)
    }

    @Test func viewportShorterThanTheIndicatorRowStaysPositive() {
        #expect(DetailMediaFrame.carouselHeight(available: 20, indicatorHeight: 38) > 0)
    }
}
