import Testing
import CoreGraphics
@testable import Diffusely

/// Regression guard for the macOS grid crash: Civitai returns 0 for some media
/// dimensions, so a raw `width / height` yields 0, ∞, or NaN. Handing a
/// non-finite value to SwiftUI's `.aspectRatio(_:contentMode:)` / frame math
/// trips an assertion inside `LayoutSubview.place` during lazy scroll prefetch —
/// a hard crash on macOS 26. `displayAspectRatio` must always be finite and > 0.
@Suite struct ImageFeedItemAspectRatioTests {
    @Test func zeroHeightIsFiniteAndPositive() {
        let ratio = ImageFeedItemView.displayAspectRatio(width: 512, height: 0)
        #expect(ratio.isFinite)
        #expect(ratio > 0)
    }

    @Test func zeroWidthIsFiniteAndPositive() {
        let ratio = ImageFeedItemView.displayAspectRatio(width: 0, height: 512)
        #expect(ratio.isFinite)
        #expect(ratio > 0)
    }

    @Test func zeroBothIsFiniteAndPositive() {
        let ratio = ImageFeedItemView.displayAspectRatio(width: 0, height: 0)
        #expect(ratio.isFinite)
        #expect(ratio > 0)
    }

    @Test func validDimensionsComputeRatio() {
        #expect(ImageFeedItemView.displayAspectRatio(width: 200, height: 100) == 2)
    }
}
