import XCTest
@testable import Diffusely

final class LibraryRootUITextTests: XCTestCase {
    func testUnavailableMessageNamesThePath() {
        let message = LibraryRootUnavailableView.message(forPath: "/Volumes/Media/Diffusely")
        XCTAssertTrue(message.contains("/Volumes/Media/Diffusely"),
                      "the user must be told WHICH folder is missing")
    }

    /// FINDING 3. A failed switch back to iCloud implicates no folder of the
    /// user's, so the gate must not name one. It used to substitute
    /// `URL(fileURLWithPath: "/")` and tell the user "Library not found at /."
    /// while offering to Locate… that.
    func testUnavailableMessageWithNoPathNamesNoPath() {
        let message = LibraryRootUnavailableView.message(forPath: nil)
        XCTAssertFalse(message.contains("/"), "must not name a path the user never chose")
        XCTAssertFalse(message.contains("not found at"))
        XCTAssertTrue(LibraryRootUnavailableView.title(forPath: nil) == "Library Unavailable")
        XCTAssertFalse(LibraryRootUnavailableView.detail(forPath: nil).contains("disk that isn't connected"),
                       "there is no folder on a disk to blame here")
    }

    func testRebuildReasonWithNoPathNamesNoPath() {
        let reason = SettingsView.rebuildIndexUnavailableReason(gate: .rootUnavailable(nil))
        XCTAssertNotNil(reason)
        XCTAssertFalse(reason!.contains("/"))
    }

    func testLocationDisplayNameForICloud() {
        XCTAssertEqual(LibraryLocationRow.displayName(for: .iCloud), "iCloud Drive")
    }

    func testLocationDisplayNameForCustomIsThePath() {
        let url = URL(fileURLWithPath: "/Volumes/Media/Diffusely Library")
        XCTAssertEqual(LibraryLocationRow.displayName(for: .custom(url)),
                       "/Volumes/Media/Diffusely Library")
    }

    func testRebuildReasonExplainsASwitchInProgress() {
        let reason = SettingsView.rebuildIndexUnavailableReason(gate: .switchingRoot)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.lowercased().contains("switching"))
    }

    func testRebuildReasonExplainsAMissingRoot() {
        let reason = SettingsView.rebuildIndexUnavailableReason(
            gate: .rootUnavailable(URL(fileURLWithPath: "/Volumes/Gone")))
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("/Volumes/Gone"))
    }

    func testRebuildReasonIsNilWhenBrowsable() {
        XCTAssertNil(SettingsView.rebuildIndexUnavailableReason(gate: .browsable))
    }

    func testResetWarningForCustomRootNamesTheFolderAndEverythingInIt() {
        let url = URL(fileURLWithPath: "/Volumes/Media/Diffusely Library")
        let warning = SettingsView.resetLibraryWarning(root: .custom(url), itemCount: 42)
        XCTAssertTrue(warning.contains("/Volumes/Media/Diffusely Library"),
                      "the user must be told WHICH folder is about to be emptied")
        XCTAssertTrue(warning.contains("everything"),
                      "must convey the whole folder goes, not just Library files")
        XCTAssertTrue(warning.contains("aren't part of your Library"),
                      "must warn that non-Library files in the folder are destroyed too")
        XCTAssertTrue(warning.contains("cannot be undone"),
                      "the last screen before an unrecoverable action must say so plainly")
    }

    func testResetWarningForICloudMentionsOtherDevicesAndIsIrreversible() {
        let warning = SettingsView.resetLibraryWarning(root: .iCloud, itemCount: 7)
        XCTAssertTrue(warning.contains("7"), "should carry the item count")
        XCTAssertTrue(warning.lowercased().contains("devices"),
                      "cross-device propagation is the most surprising consequence for an iCloud user")
        XCTAssertTrue(warning.contains("cannot be undone"),
                      "the last screen before an unrecoverable action must say so plainly")
    }
}
