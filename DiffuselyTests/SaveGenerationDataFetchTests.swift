import Testing
import Foundation
@testable import Diffusely

/// The save-time generation-data fetch used to be a bare `try?`, so ANY
/// failure — a timeout, a 429, a tRPC shape change — silently persisted a
/// sidecar with no generation data, permanently and with no record that an
/// attempt had ever been made. Measured on a real library, 81 items had been
/// lost that way and 16 of 25 sampled still had a checkpoint on Civitai.
///
/// These pin the replacement's decision table, which is deliberately pure so
/// it can be exercised without a network or a `CivitaiService`.
@Suite struct SaveGenerationDataFetchTests {

    private func gen(_ name: String) -> GenerationData {
        GenerationData(type: "image", meta: nil, resources: [
            GenerationResource(modelId: 1, modelName: name, modelType: "Checkpoint",
                               versionId: 1, versionName: "v1", strength: 1)
        ])
    }

    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func noData() -> Error {
        DecodingError.valueNotFound(
            GenerationData.self,
            DecodingError.Context(codingPath: [], debugDescription: "result.data.json was null"))
    }

    @Test func returnsDataOnFirstTryAndStampsNoMarker() async {
        var calls = 0
        let result = await LibrarySaveService.fetchGenerationDataForSave(now: { self.fixedNow }) {
            calls += 1
            return self.gen("Pony Diffusion V6 XL")
        }
        #expect(calls == 1)
        #expect(result.data?.resources?.first?.modelName == "Pony Diffusion V6 XL")
        #expect(result.attemptedAt == nil)
    }

    @Test func retriesOnceAfterATransientFailure() async {
        // The whole point: one dropped connection must not cost the item its
        // generation data for good.
        var calls = 0
        let result = await LibrarySaveService.fetchGenerationDataForSave(now: { self.fixedNow }) {
            calls += 1
            if calls == 1 { throw URLError(.networkConnectionLost) }
            return self.gen("Hassaku XL")
        }
        #expect(calls == 2)
        #expect(result.data?.resources?.first?.modelName == "Hassaku XL")
        #expect(result.attemptedAt == nil)
    }

    @Test func leavesTheMarkerNilWhenEveryAttemptFailsTransiently() async {
        // Marker stays nil so `computeNeedsGenerationDataBackfill` stays true
        // and the backfill picks the item up next session.
        var calls = 0
        let result = await LibrarySaveService.fetchGenerationDataForSave(now: { self.fixedNow }) {
            calls += 1
            throw URLError(.timedOut)
        }
        #expect(calls == 2)
        #expect(result.data == nil)
        #expect(result.attemptedAt == nil)

        let metadata = Self.metadata(generationData: result.data, attemptedAt: result.attemptedAt)
        #expect(PersistedLibraryItem.computeNeedsGenerationDataBackfill(for: metadata))
    }

    @Test func stampsTheMarkerWhenCivitaiConfirmsThereIsNoData() async {
        // `result.data.json` is null — a decode failure, and a final answer.
        // Stamping here means the backfill never wastes a request on it.
        var calls = 0
        let result = await LibrarySaveService.fetchGenerationDataForSave(now: { self.fixedNow }) {
            calls += 1
            throw self.noData()
        }
        #expect(result.data == nil)
        #expect(result.attemptedAt == fixedNow)

        let metadata = Self.metadata(generationData: result.data, attemptedAt: result.attemptedAt)
        #expect(!PersistedLibraryItem.computeNeedsGenerationDataBackfill(for: metadata))
    }

    @Test func doesNotRetryAConfirmedNoData() async {
        // Retrying a final answer is a wasted request on every single save.
        var calls = 0
        _ = await LibrarySaveService.fetchGenerationDataForSave(now: { self.fixedNow }) {
            calls += 1
            throw self.noData()
        }
        #expect(calls == 1)
    }

    @Test func aTransientFailureFollowedByNoDataIsTreatedAsNoData() async {
        // The marker must reflect the LAST answer, not the first — otherwise a
        // blip followed by a definitive "nothing here" leaves the item on the
        // backfill queue forever.
        var calls = 0
        let result = await LibrarySaveService.fetchGenerationDataForSave(now: { self.fixedNow }) {
            calls += 1
            if calls == 1 { throw URLError(.timedOut) }
            throw self.noData()
        }
        #expect(calls == 2)
        #expect(result.attemptedAt == fixedNow)
    }

    @Test func neverThrowsSoAFetchFailureCannotFailTheSave() async {
        // The media is already downloaded by this point; losing the whole save
        // over optional metadata would be a much worse trade.
        let result = await LibrarySaveService.fetchGenerationDataForSave(now: { self.fixedNow }) {
            throw URLError(.badServerResponse)
        }
        #expect(result.data == nil)
    }

    private static func metadata(generationData: GenerationData?, attemptedAt: Date?) -> LibraryItemMetadata {
        LibraryItemMetadata(
            schemaVersion: LibraryItemMetadata.currentSchemaVersion,
            itemID: 1, sourcePostID: nil, sourcePostTitle: nil, canonicalPostURL: nil,
            canonicalPageURL: "u", sourceDomain: "civitai.com", originalCDNURL: "u",
            mediaType: .image, mediaFileName: "1.jpeg", fileByteSize: 1, contentSHA256: "x",
            width: 1, height: 1, nsfwLevel: 1,
            author: LibraryAuthor(id: nil, username: nil, avatarURL: nil),
            stats: nil, generationData: generationData, publishedAt: nil,
            generationDataBackfillAttemptedAt: attemptedAt,
            savedAt: Date(), savedByAppVersion: "t"
        )
    }
}
