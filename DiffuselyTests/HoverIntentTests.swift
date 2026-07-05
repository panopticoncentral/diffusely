import Testing
@testable import Diffusely

@MainActor
@Suite struct HoverIntentTests {
    /// A hover that lasts past the delay arms the intent.
    @Test func sustainedHoverArms() async {
        let intent = HoverIntent(delay: .zero)
        await intent.begin().value
        #expect(intent.isArmed)
    }

    /// A hover cancelled before the delay elapses never arms.
    @Test func quickHoverDoesNotArm() async {
        let intent = HoverIntent(delay: .milliseconds(100))
        let pending = intent.begin()
        intent.cancel()
        await pending.value
        #expect(!intent.isArmed)
    }

    /// cancel() after arming disarms.
    @Test func cancelAfterArmingDisarms() async {
        let intent = HoverIntent(delay: .zero)
        await intent.begin().value
        #expect(intent.isArmed)
        intent.cancel()
        #expect(!intent.isArmed)
    }
}
