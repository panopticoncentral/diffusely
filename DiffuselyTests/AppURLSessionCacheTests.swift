import Testing
import Foundation
@testable import Diffusely

@Suite struct AppURLSessionTests {
    @Test func civitaiSessionHasBoundedTimeouts() {
        #expect(URLSession.civitai.configuration.timeoutIntervalForRequest == 20)
        #expect(URLSession.civitai.configuration.timeoutIntervalForResource == 300)
    }

    @Test func civitaiSessionHasNoDelegate() {
        #expect(URLSession.civitai.delegate == nil)
    }
}
