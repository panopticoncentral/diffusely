import Foundation

/// Slice of `CivitaiService` that `ManageCollectionsViewModel` depends on.
/// Exists so VM tests can inject a fake; production code passes a real
/// `CivitaiService`.
@MainActor
protocol ManageCollectionsAPI {
    func getUserImageCollections() async throws -> [CivitaiCollection]
    func getUserPostCollections() async throws -> [CivitaiCollection]
    func getUserCollectionItemsByItem(target: ManageCollectionsTarget) async throws -> [Int]
    func saveItem(target: ManageCollectionsTarget, adding: [Int], removing: [Int]) async throws
}

extension CivitaiService: ManageCollectionsAPI {}
