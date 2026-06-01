import Testing
import Foundation
@testable import Diffusely

@Suite struct AppURLSessionCacheTests {
    @Test func civitaiSessionHasDiskBackedImageCache() {
        let cache = URLSession.civitai.configuration.urlCache
        #expect(cache != nil)
        #expect((cache?.diskCapacity ?? 0) >= 500 * 1024 * 1024)
        #expect((cache?.memoryCapacity ?? 0) >= 50 * 1024 * 1024)
    }

    @Test func civitaiSessionUsesForcingDelegate() {
        #expect(URLSession.civitai.delegate is ImageCacheForcingDelegate)
    }

    @Test func civitaiSessionUsesProtocolCachePolicy() {
        #expect(URLSession.civitai.configuration.requestCachePolicy == .useProtocolCachePolicy)
    }

    @Test func imageCacheDirectoryIsInApplicationSupport() {
        let directory = URLSession.imageCacheDirectory()
        #expect(directory != nil)
        let path = directory?.path ?? ""
        #expect(path.contains("Application Support"))
        #expect(path.hasSuffix("NetworkImageCache"))
        #expect(!path.contains("/Caches/"))
    }
}
