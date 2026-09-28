import XCTest
@testable import Diffusely

final class LibraryKeyStoreTests: XCTestCase {
    func testInMemoryStoreRoundTrips() async throws {
        let store = InMemoryKeyStore()
        let initial = try await store.loadWithBiometrics(reason: "test", vaultID: "test")
        XCTAssertNil(initial)
        try store.store(dek: Data([1, 2, 3]), vaultID: "test")
        let loaded = try await store.loadWithBiometrics(reason: "test", vaultID: "test")
        XCTAssertEqual(loaded, Data([1, 2, 3]))
        try store.clear(vaultID: "test")
        let afterClear = try await store.loadWithBiometrics(reason: "test", vaultID: "test")
        XCTAssertNil(afterClear)
    }
}
