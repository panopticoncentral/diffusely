import Testing
import Foundation
@testable import Diffusely
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Suite struct LibraryThumbnailStoreTests {
    // A 4x4 solid-color image we can encode/decode.
    func makeImage() -> PlatformImage {
        let size = CGSize(width: 4, height: 4)
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }
        #else
        let img = NSImage(size: size)
        img.lockFocus(); NSColor.red.setFill(); NSRect(origin: .zero, size: size).fill(); img.unlockFocus()
        return img
        #endif
    }

    func makeStore() -> LibraryThumbnailStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumbtest-\(UUID().uuidString)", isDirectory: true)
        return LibraryThumbnailStore(directory: dir)
    }

    @Test func storeThenRetrieveRoundTrips() {
        let store = makeStore()
        #expect(store.thumbnail(itemID: 1) == nil)        // miss before store
        store.store(makeImage(), itemID: 1)
        #expect(store.thumbnail(itemID: 1) != nil)        // hit after store
    }

    @Test func removeDeletesOne() {
        let store = makeStore()
        store.store(makeImage(), itemID: 1)
        store.store(makeImage(), itemID: 2)
        store.remove(itemID: 1)
        #expect(store.thumbnail(itemID: 1) == nil)
        #expect(store.thumbnail(itemID: 2) != nil)
    }

    @Test func removeAllClearsEverything() {
        let store = makeStore()
        store.store(makeImage(), itemID: 1)
        store.store(makeImage(), itemID: 2)
        store.removeAll()
        #expect(store.thumbnail(itemID: 1) == nil)
        #expect(store.thumbnail(itemID: 2) == nil)
    }

    @Test func corruptFileReadsAsMiss() throws {
        let store = makeStore()
        try store.writeRawForTesting(Data([0x00, 0x01, 0x02]), itemID: 7)
        #expect(store.thumbnail(itemID: 7) == nil)
    }
}
