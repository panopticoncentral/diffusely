import Testing
import Foundation
@testable import Diffusely

// MARK: - Helpers

private func makeMeta(
    itemID: Int,
    mediaType: LibraryMediaType = .image,
    savedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    generationData: GenerationData? = nil
) -> LibraryItemMetadata {
    LibraryItemMetadata(
        schemaVersion: LibraryItemMetadata.currentSchemaVersion,
        itemID: itemID,
        sourcePostID: nil,
        sourcePostTitle: nil,
        canonicalPostURL: nil,
        canonicalPageURL: "https://civitai.com/images/\(itemID)",
        sourceDomain: "civitai.com",
        originalCDNURL: "https://image.civitai.com/x/u/original=true/\(itemID).\(mediaType.fileExtension)",
        mediaType: mediaType,
        mediaFileName: "\(itemID).\(mediaType.fileExtension)",
        fileByteSize: 1,
        contentSHA256: "x",
        width: 1, height: 1, nsfwLevel: 1,
        author: LibraryAuthor(id: 1, username: "alice", avatarURL: nil),
        stats: nil,
        generationData: generationData,
        publishedAt: nil,
        savedAt: savedAt,
        savedByAppVersion: "t"
    )
}

private func resource(_ type: String?, _ name: String?) -> GenerationResource {
    GenerationResource(modelId: 1, modelName: name, modelType: type,
                       versionId: 1, versionName: "v1", strength: 1)
}

private func day(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    return f.date(from: iso)!
}

// MARK: - Classification

@Suite struct LibraryCheckpointClassificationTests {

    @Test func sidecarWithNoGenerationDataIsNoGenerationData() {
        let finding = LibraryCheckpointDiagnostics.classify(makeMeta(itemID: 1, generationData: nil))
        #expect(finding.kind == .noGenerationData)
        #expect(finding.checkpointName == nil)
        #expect(finding.resourceTypes.isEmpty)
    }

    @Test func generationDataWithNilResourcesIsNoResources() {
        let gen = GenerationData(type: "image", meta: nil, resources: nil)
        #expect(LibraryCheckpointDiagnostics.classify(makeMeta(itemID: 2, generationData: gen)).kind == .noResources)
    }

    @Test func generationDataWithEmptyResourcesIsNoResources() {
        let gen = GenerationData(type: "image", meta: nil, resources: [])
        #expect(LibraryCheckpointDiagnostics.classify(makeMeta(itemID: 3, generationData: gen)).kind == .noResources)
    }

    @Test func resourcesWithoutACheckpointAreNoCheckpointResource() {
        // The dominant real-world shape: Civitai hash-matched the LoRAs but
        // never matched a base model (ComfyUI / off-site uploads).
        let gen = GenerationData(type: "image", meta: nil, resources: [
            resource("LORA", "SomeLora"),
            resource("TextualInversion", "EasyNegative")
        ])
        let finding = LibraryCheckpointDiagnostics.classify(makeMeta(itemID: 4, generationData: gen))
        #expect(finding.kind == .noCheckpointResource)
        #expect(finding.resourceTypes == ["LORA", "TextualInversion"])
    }

    @Test func checkpointResourceWithBlankNameIsItsOwnCase() {
        // Distinct from `.noCheckpointResource`: the resource IS there, so a
        // network re-fetch wouldn't help — only naming would.
        for name in [nil, "", "   "] as [String?] {
            let gen = GenerationData(type: "image", meta: nil, resources: [resource("Checkpoint", name)])
            #expect(LibraryCheckpointDiagnostics.classify(makeMeta(itemID: 5, generationData: gen)).kind
                    == .checkpointNameBlank)
        }
    }

    @Test func checkpointResourceWithANameIsHasCheckpoint() {
        let gen = GenerationData(type: "image", meta: nil, resources: [
            resource("LORA", "SomeLora"),
            resource("Checkpoint", "Pony Diffusion V6 XL")
        ])
        let finding = LibraryCheckpointDiagnostics.classify(makeMeta(itemID: 6, generationData: gen))
        #expect(finding.kind == .hasCheckpoint)
        #expect(finding.checkpointName == "Pony Diffusion V6 XL")
    }

    @Test func derivationMatchesPersistedLibraryItemExactly() {
        // The diagnostic is only trustworthy if it reproduces the real
        // derivation in `PersistedLibraryItem.init(metadata:downloadStatus:)`:
        // FIRST resource whose modelType is exactly "Checkpoint".
        let cases: [GenerationData?] = [
            nil,
            GenerationData(type: "image", meta: nil, resources: nil),
            GenerationData(type: "image", meta: nil, resources: []),
            GenerationData(type: "image", meta: nil, resources: [resource("LORA", "L")]),
            GenerationData(type: "image", meta: nil, resources: [resource("checkpoint", "lowercase")]),
            GenerationData(type: "image", meta: nil, resources: [resource("Checkpoint", "Alpha"),
                                                                 resource("Checkpoint", "Beta")]),
            GenerationData(type: "image", meta: nil, resources: [resource("LORA", "L"),
                                                                 resource("Checkpoint", "Gamma")])
        ]
        for gen in cases {
            let meta = makeMeta(itemID: 7, generationData: gen)
            let row = PersistedLibraryItem(metadata: meta, downloadStatus: .downloaded)
            let finding = LibraryCheckpointDiagnostics.classify(meta)
            #expect(finding.checkpointName == row.checkpointName)
        }
    }

    @Test func lowercaseCheckpointTypeDoesNotCount() {
        // Documents the exact-string match: if Civitai ever returned
        // "checkpoint", this case would light up in the report instead of
        // silently grouping.
        let gen = GenerationData(type: "image", meta: nil, resources: [resource("checkpoint", "A-mix")])
        let finding = LibraryCheckpointDiagnostics.classify(makeMeta(itemID: 8, generationData: gen))
        #expect(finding.kind == .noCheckpointResource)
        #expect(finding.resourceTypes == ["checkpoint"])
    }
}

// MARK: - Index cross-check

@Suite struct LibraryCheckpointIndexCrossCheckTests {

    @Test func flagsSidecarWithCheckpointWhoseIndexRowHasNone() {
        // The bug signature that says "re-derive from disk", not "re-fetch
        // from the network".
        let gen = GenerationData(type: "image", meta: nil, resources: [resource("Checkpoint", "Hassaku")])
        let report = LibraryCheckpointDiagnostics.report(
            findings: [LibraryCheckpointDiagnostics.classify(makeMeta(itemID: 9, generationData: gen))],
            indexCheckpointNames: [:]
        )
        #expect(report.indexDisagreements.map(\.itemID) == [9])
    }

    @Test func agreeingIndexRowIsNotFlagged() {
        let gen = GenerationData(type: "image", meta: nil, resources: [resource("Checkpoint", "Hassaku")])
        let report = LibraryCheckpointDiagnostics.report(
            findings: [LibraryCheckpointDiagnostics.classify(makeMeta(itemID: 10, generationData: gen))],
            indexCheckpointNames: [10: "Hassaku"]
        )
        #expect(report.indexDisagreements.isEmpty)
    }

    @Test func indexRowHoldingANameTheSidecarLacksIsAlsoFlagged() {
        // The reverse drift: a stale row the container no longer backs.
        let report = LibraryCheckpointDiagnostics.report(
            findings: [LibraryCheckpointDiagnostics.classify(makeMeta(itemID: 11, generationData: nil))],
            indexCheckpointNames: [11: "Ghost"]
        )
        #expect(report.indexDisagreements.map(\.itemID) == [11])
    }
}

// MARK: - Aggregation

@Suite struct LibraryCheckpointReportTests {

    private func findings() -> [LibraryCheckpointDiagnostics.Finding] {
        let ckpt = GenerationData(type: "image", meta: nil, resources: [resource("Checkpoint", "Pony")])
        let lora = GenerationData(type: "image", meta: nil, resources: [resource("LORA", "L")])
        return [
            LibraryCheckpointDiagnostics.classify(makeMeta(itemID: 1, savedAt: day("2026-08-12T10:00:00Z"), generationData: ckpt)),
            LibraryCheckpointDiagnostics.classify(makeMeta(itemID: 2, savedAt: day("2026-08-12T11:00:00Z"), generationData: lora)),
            LibraryCheckpointDiagnostics.classify(makeMeta(itemID: 3, savedAt: day("2026-08-12T12:00:00Z"), generationData: lora)),
            LibraryCheckpointDiagnostics.classify(makeMeta(itemID: 4, mediaType: .video, savedAt: day("2026-08-13T09:00:00Z"), generationData: nil)),
            LibraryCheckpointDiagnostics.classify(makeMeta(itemID: 5, savedAt: day("2026-08-13T09:30:00Z"),
                                                           generationData: GenerationData(type: "image", meta: nil, resources: [])))
        ]
    }

    @Test func countsEachCase() {
        let report = LibraryCheckpointDiagnostics.report(findings: findings(), indexCheckpointNames: [:])
        #expect(report.total == 5)
        #expect(report.count(of: .hasCheckpoint) == 1)
        #expect(report.count(of: .noCheckpointResource) == 2)
        #expect(report.count(of: .noGenerationData) == 1)
        #expect(report.count(of: .noResources) == 1)
        #expect(report.count(of: .checkpointNameBlank) == 0)
    }

    @Test func groupsUngroupedItemsTheWayTheLibraryDoes() {
        // Everything without a checkpoint lands in "Videos" (video) or
        // "Other" (image) — the two buckets in `groupByCheckpoint`.
        let report = LibraryCheckpointDiagnostics.report(findings: findings(), indexCheckpointNames: [:])
        #expect(report.otherBucketCount == 3)   // items 2, 3, 5
        #expect(report.videosBucketCount == 1)  // item 4
    }

    @Test func histogramsResourceTypesSeenOnUngroupedItems() {
        let report = LibraryCheckpointDiagnostics.report(findings: findings(), indexCheckpointNames: [:])
        #expect(report.resourceTypeHistogram == ["LORA": 2])
    }

    @Test func histogramsSaveDaysForUngroupedItemsOnly() {
        // A day that is entirely ungrouped points at a save-time fetch
        // failure window; a low background rate points at content that has
        // no checkpoint on Civitai at all.
        let report = LibraryCheckpointDiagnostics.report(findings: findings(), indexCheckpointNames: [:])
        #expect(report.saveDayHistogram["2026-08-12"] == .init(total: 3, ungrouped: 2))
        #expect(report.saveDayHistogram["2026-08-13"] == .init(total: 2, ungrouped: 2))
    }

    @Test func textReportNamesEveryCaseAndIsCopyable() {
        let text = LibraryCheckpointDiagnostics.report(findings: findings(), indexCheckpointNames: [:]).text
        #expect(text.contains("5 sidecars"))
        for kind in LibraryCheckpointDiagnostics.Kind.allCases {
            #expect(text.contains(kind.label))
        }
        #expect(text.contains("2026-08-12"))
    }

    @Test func emptyLibraryProducesAReportRatherThanCrashing() {
        let report = LibraryCheckpointDiagnostics.report(findings: [], indexCheckpointNames: [:])
        #expect(report.total == 0)
        #expect(report.text.contains("0 sidecars"))
    }
}
