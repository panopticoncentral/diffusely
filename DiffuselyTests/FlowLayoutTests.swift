import Testing
import CoreGraphics
@testable import Diffusely

@Suite struct FlowLayoutTests {
    private let chip = CGSize(width: 50, height: 20)

    /// Regression guard for the macOS beachball: SwiftUI probes a Layout with an
    /// infinite proposed width, and returning a non-finite width there produces
    /// an invalid AppKit frame that spins the main thread in a re-layout loop.
    @Test func infiniteProposedWidthReturnsFiniteSize() {
        let size = FlowLayout.flowSize(subviewSizes: [chip, chip, chip], proposedWidth: .infinity, spacing: 8)
        #expect(size.width.isFinite)
        #expect(size.height.isFinite)
    }

    @Test func nilProposedWidthReturnsFiniteIntrinsicWidth() {
        let size = FlowLayout.flowSize(subviewSizes: [chip, chip], proposedWidth: nil, spacing: 8)
        #expect(size.width.isFinite)
        // Single row: 50 + 8 + 50 + 8 - 8 = 108
        #expect(size.width == 108)
        #expect(size.height == 20)
    }

    @Test func finiteProposedWidthFillsThatWidthAndWraps() {
        // 120pt fits two 50pt chips (50+8+50 = 108); the third wraps to row 2.
        let size = FlowLayout.flowSize(subviewSizes: [chip, chip, chip], proposedWidth: 120, spacing: 8)
        #expect(size.width == 120)
        // Two rows: 20 + 8 + 20 = 48
        #expect(size.height == 48)
    }

    @Test func emptyReturnsFiniteZeroHeight() {
        let size = FlowLayout.flowSize(subviewSizes: [], proposedWidth: .infinity, spacing: 8)
        #expect(size.width.isFinite)
        #expect(size.height == 0)
    }
}
