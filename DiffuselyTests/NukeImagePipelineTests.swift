import Testing
import Nuke
@testable import Diffusely

@Suite struct NukeImagePipelineTests {
    @Test func configureInstallsSharedPipelineWithCaches() {
        AppImagePipeline.configure()
        let config = ImagePipeline.shared.configuration
        #expect(config.dataCache != nil)        // durable cross-launch disk cache
        #expect(config.imageCache != nil)       // in-memory decoded tier
    }
}
