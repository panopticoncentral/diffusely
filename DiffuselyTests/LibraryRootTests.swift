import XCTest
@testable import Diffusely

final class LibraryRootTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "LibraryRootTests-\(UUID().uuidString)")!
        return suite
    }

    func testICloudCapabilities() {
        let caps = LibraryRoot.iCloud.capabilities
        XCTAssertTrue(caps.allowsEncryption)
        XCTAssertTrue(caps.usesMetadataQuery)
        XCTAssertTrue(caps.supportsCacheLimit)
    }

    func testCustomCapabilitiesAreAllOff() {
        let caps = LibraryRoot.custom(URL(fileURLWithPath: "/tmp/x", isDirectory: true)).capabilities
        XCTAssertFalse(caps.allowsEncryption)
        XCTAssertFalse(caps.usesMetadataQuery)
        XCTAssertFalse(caps.supportsCacheLimit)
    }

    func testLoadDefaultsToICloudWhenNothingStored() {
        let store = LibraryRootStore(defaults: makeDefaults())
        XCTAssertEqual(store.load(), .iCloud)
    }

    func testCustomRootRoundTrips() {
        let store = LibraryRootStore(defaults: makeDefaults())
        let url = URL(fileURLWithPath: "/Volumes/Media/Diffusely Library", isDirectory: true)
        store.save(.custom(url))
        XCTAssertEqual(store.load(), .custom(url))
    }

    func testSavingICloudClearsAnyStoredPath() {
        let defaults = makeDefaults()
        let store = LibraryRootStore(defaults: defaults)
        store.save(.custom(URL(fileURLWithPath: "/tmp/lib", isDirectory: true)))
        store.save(.iCloud)
        XCTAssertEqual(store.load(), .iCloud)
        XCTAssertNil(defaults.string(forKey: LibraryRootStore.defaultsKey))
    }

    /// A stored root whose folder has since disappeared must still LOAD, so the
    /// blocked-state UI can name the missing path. Validation is a separate step.
    func testLoadDoesNotValidateThePath() {
        let store = LibraryRootStore(defaults: makeDefaults())
        let gone = URL(fileURLWithPath: "/Volumes/Unplugged/Library", isDirectory: true)
        store.save(.custom(gone))
        XCTAssertEqual(store.load(), .custom(gone))
    }
}
