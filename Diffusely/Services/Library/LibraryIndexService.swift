import Foundation
import SwiftData

/// Owns all writes to the disposable `PersistedLibraryItem` index. The container
/// (media + sidecar JSON) is the source of truth; this index is rebuilt from it on
/// launch and whenever iCloud reports changes, and can be wiped and regenerated at
/// any time without data loss.
@ModelActor
actor LibraryIndexService {

    // MARK: - Mutation epoch

    /// Monotonic count of direct index mutations (ingests, deletes, album
    /// rows, membership changes). A reconcile captures it before scanning and
    /// only applies the scan if it hasn't moved — the fence that stops a
    /// stale container snapshot from overwriting newer rows (the
    /// "items reappear in Not in any Album" bug).
    private var mutationEpoch = 0

    func currentMutationEpoch() -> Int { mutationEpoch }

    /// Every mutator whose effect a stale scan could wrongly undo calls this
    /// on entry — unconditional (even if the mutation turns out to be a no-op):
    /// cheap, and a false-positive rescan is harmless while a missed bump is
    /// the clobber bug. `recordAccess`/`setStatus`/`enforceCacheLimit` are
    /// deliberately excluded: they change only ephemeral fields (last access,
    /// download status) that the next reconcile re-derives anyway, and they
    /// fire often enough to starve reconcile's bounded rescan loop.
    private func bumpMutationEpoch() { mutationEpoch += 1 }

    /// Outcome of applying a container scan to the index.
    enum ScanApplication: Equatable {
        /// A direct write landed after the scan's epoch was captured; the stale
        /// snapshot was rejected and the caller should rescan.
        case rejectedStaleEpoch
        /// The scan was applied. `albumStateChanged` is true when it altered
        /// album rows or any item's membership — UI that renders album state
        /// won't see those edits through `itemCount` and must be reloaded.
        case applied(albumStateChanged: Bool)

        var wasApplied: Bool { self != .rejectedStaleEpoch }
    }

    // MARK: - Upsert

    func ingest(metadata: LibraryItemMetadata, downloadStatus: LibraryDownloadStatus) {
        bumpMutationEpoch()
        if let existing = fetchItem(itemID: metadata.itemID) {
            apply(metadata, downloadStatus: downloadStatus, to: existing)
        } else {
            modelContext.insert(PersistedLibraryItem(metadata: metadata, downloadStatus: downloadStatus))
        }
        try? modelContext.save()
    }

    /// Copies the mutable fields from a freshly-read sidecar onto an existing
    /// index row. Pure in-memory work — no fetch, no save. Returns whether the
    /// row's album membership changed, so reconcile can signal album-observing UI.
    /// `sidecarFileName`/`sidecarModifiedAt`/`sidecarByteSize` default to the
    /// "unknown" state so callers that don't come from a container scan (e.g.
    /// `ingest`, used by the backfill services) leave the row's fingerprint
    /// unknown rather than stamping it with a stale one — those callers
    /// rewrite the sidecar without going through the scan's directory
    /// listing, so they have no fingerprint to report, and "unknown" is
    /// always safe: it only ever costs a redundant re-read, never a wrong
    /// skip.
    ///
    /// Concretely, `ingest()`'s three call sites — `LibrarySaveService`
    /// (a freshly-saved item), `LibraryDateBackfillService`, and
    /// `LibraryCheckpointBackfillService` — all leave these parameters
    /// defaulted. That's correct, not an oversight: each of them rewrites
    /// the sidecar to disk immediately before calling `ingest`, so any
    /// fingerprint they could report would already be stale by the time a
    /// later scan compared it, and defaulting to "unknown" simply forces
    /// that one self-correcting re-read on the next scan instead.
    @discardableResult
    private func apply(
        _ metadata: LibraryItemMetadata,
        downloadStatus: LibraryDownloadStatus,
        sidecarFileName: String = "",
        sidecarModifiedAt: Date? = nil,
        sidecarByteSize: Int = 0,
        to row: PersistedLibraryItem
    ) -> Bool {
        row.mediaType = metadata.mediaType.rawValue
        row.mediaFileName = metadata.mediaFileName
        row.width = metadata.width
        row.height = metadata.height
        row.nsfwLevel = metadata.nsfwLevel
        row.authorUsername = metadata.author.username
        row.authorAvatarURL = metadata.author.avatarURL
        row.sourcePostID = metadata.sourcePostID
        row.canonicalPageURL = metadata.canonicalPageURL
        row.fileByteSize = metadata.fileByteSize
        row.savedAt = metadata.savedAt
        row.publishedAt = metadata.publishedAt
        row.needsDateBackfill = PersistedLibraryItem.computeNeedsDateBackfill(for: metadata)
        row.needsGenerationDataBackfill = PersistedLibraryItem.computeNeedsGenerationDataBackfill(for: metadata)
        row.checkpointName = metadata.generationData?
            .resources?
            .first(where: { $0.modelType == "Checkpoint" })?
            .modelName
        row.downloadStatus = downloadStatus
        row.sidecarFileName = sidecarFileName
        row.sidecarModifiedAt = sidecarModifiedAt
        row.sidecarByteSize = sidecarByteSize
        let newAlbumIDsJoined = PersistedLibraryItem.join(metadata.albumIDs)
        let membershipChanged = row.albumIDsJoined != newAlbumIDsJoined
        row.albumIDsJoined = newAlbumIDsJoined
        return membershipChanged
    }

    func remove(itemID: Int) {
        bumpMutationEpoch()
        if let existing = fetchItem(itemID: itemID) {
            modelContext.delete(existing)
            try? modelContext.save()
        }
    }

    /// Batch-deletes index rows for the given ids in a single save. Used by the
    /// Library multi-select delete so removing N items is one persistence
    /// transaction instead of N. Unknown ids are skipped.
    func remove(itemIDs: [Int]) {
        guard !itemIDs.isEmpty else { return }
        bumpMutationEpoch()
        var changed = false
        for itemID in itemIDs {
            if let existing = fetchItem(itemID: itemID) {
                modelContext.delete(existing)
                changed = true
            }
        }
        if changed { try? modelContext.save() }
    }

    // MARK: - Albums

    func upsertAlbum(_ file: LibraryAlbumFile) {
        bumpMutationEpoch()
        if let existing = fetchAlbum(id: file.id) {
            Self.apply(file, to: existing)
        } else {
            modelContext.insert(PersistedAlbum(file: file))
        }
        try? modelContext.save()
    }

    /// Copies all denormalized fields from an album file onto an index row.
    /// Returns whether anything observable changed (drives the albumsVersion
    /// reload signal).
    @discardableResult
    private static func apply(_ file: LibraryAlbumFile, to row: PersistedAlbum) -> Bool {
        let changed = row.name != file.name || row.createdAt != file.createdAt
            || row.userDescription != file.userDescription
            || row.aiProfileText != file.aiProfile?.text
            || row.aiProfileBuiltAt != file.aiProfile?.builtAt
            || row.aiProfileMemberCount != (file.aiProfile?.memberCount ?? 0)
        row.name = file.name
        row.createdAt = file.createdAt
        row.userDescription = file.userDescription
        row.aiProfileText = file.aiProfile?.text
        row.aiProfileBuiltAt = file.aiProfile?.builtAt
        row.aiProfileMemberCount = file.aiProfile?.memberCount ?? 0
        return changed
    }

    func removeAlbum(id: UUID) {
        bumpMutationEpoch()
        if let existing = fetchAlbum(id: id) {
            modelContext.delete(existing)
            try? modelContext.save()
        }
    }

    /// Replaces an item row's membership. The sidecar is the source of truth and
    /// must already have been rewritten by the caller; this just keeps the index
    /// row in step without re-reading media or download status.
    func setAlbumIDs(itemID: Int, albumIDs: [String]) {
        setAlbumIDs([(itemID, albumIDs)])
    }

    /// Batch variant: one mutation epoch and ONE save for the whole update.
    /// Accepting a large Sort Assistant group was N per-item saves, and the
    /// main thread's own fetches contend with each one on the shared SQLite
    /// store — visible as beachballs during accepts.
    func setAlbumIDs(_ updates: [(itemID: Int, albumIDs: [String])]) {
        guard !updates.isEmpty else { return }
        bumpMutationEpoch()
        var changed = false
        for (itemID, albumIDs) in updates {
            guard let row = fetchItem(itemID: itemID) else { continue }
            row.albumIDsJoined = PersistedLibraryItem.join(albumIDs)
            changed = true
        }
        if changed { try? modelContext.save() }
    }

    private func fetchAlbum(id: UUID) -> PersistedAlbum? {
        var d = FetchDescriptor<PersistedAlbum>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? modelContext.fetch(d).first
    }

    func recordAccess(itemID: Int, status: LibraryDownloadStatus? = nil) {
        guard let existing = fetchItem(itemID: itemID) else { return }
        existing.lastAccessedAt = Date()
        if let status { existing.downloadStatus = status }
        try? modelContext.save()
    }

    func setStatus(itemID: Int, status: LibraryDownloadStatus) {
        guard let existing = fetchItem(itemID: itemID) else { return }
        existing.downloadStatus = status
        try? modelContext.save()
    }

    func currentDownloadStatus(itemID: Int) -> LibraryDownloadStatus? {
        fetchItem(itemID: itemID)?.downloadStatus
    }

    // MARK: - Reconcile (container -> index)

    /// Diffs the container against the index: ingests every readable sidecar
    /// (including ones synced from other devices), drops rows whose sidecar
    /// vanished, and ignores media without a committed JSON.
    ///
    /// The directory walk, per-sidecar `Data(contentsOf:)` reads, and per-media
    /// iCloud status lookups are all blocking syscalls — and the iCloud ones
    /// round-trip to the FileProvider daemon, blocking for a long time when a
    /// sidecar is a not-yet-materialized placeholder. The scan therefore runs on
    /// a dedicated serial queue (`scanQueue`), NOT `Task.detached`: a detached
    /// task runs on the Swift concurrency cooperative pool, and a blocking
    /// syscall there burns a cooperative thread. Overlapping reconciles (iCloud
    /// churn) would then block every cooperative thread at once and starve all
    /// `async` work app-wide — including image loading, which stranded the feed
    /// on permanent grey spinners. `withCheckedContinuation` suspends the caller
    /// without holding a cooperative thread, and the serial queue guarantees at
    /// most one blocked scan thread ever. Only the SwiftData writes below touch
    /// the model actor.
    /// Returns whether the reconcile changed album-relevant state (album rows or
    /// item membership) — those edits are invisible to `itemCount`, so the caller
    /// must signal album-observing UI when this is true. A skipped reconcile
    /// (unreadable container, or direct writes kept landing) returns false: the
    /// metadata query re-fires for every container change, so a follow-up
    /// reconcile reports the change instead.
    /// What a reconcile pass learned.
    ///
    /// `pendingItems`/`pendingAlbums` are OPTIONAL on purpose: a reconcile that
    /// never completed a scan — locked vault, unreadable container, or repeated
    /// direct-write collisions — knows nothing about the backlog. Reporting `0`
    /// there would read as "everything is downloaded" and wrongly clear the
    /// Library's status; `nil` tells the caller to leave the last known figure
    /// alone.
    struct ReconcileOutcome: Equatable {
        var albumStateChanged = false
        var pendingItems: Int?
        var pendingAlbums: Int?

        /// Outcome of a pass that never got to look at the container.
        static let didNotScan = ReconcileOutcome()
    }

    @discardableResult
    func reconcile(
        itemsDirectory: URL,
        isPlaceholder: @escaping PlaceholderCheck = { isDatalessPlaceholder($0) },
        startedAtGeneration: Int? = nil,
        generationProbe: @Sendable @escaping () async -> Int = {
            await LibraryContainer.shared.rootGeneration
        },
        // Task 4 (skip unchanged sidecars): true for every normal reconcile.
        // `rebuild` passes `false` so "Rebuild Index" means "distrust the
        // index" and never consults the very fingerprints it exists to
        // rebuild.
        useFingerprints: Bool = true
    ) async -> ReconcileOutcome {
        // Load-bearing guard: a configured-but-LOCKED vault has no DEK, so a
        // store built with `crypto == nil` is a plain passthrough —
        // indistinguishable from `.notConfigured` — that would scan for
        // `*.json` sidecars, find none of the real `*.m`/`*.x` files, and
        // prune the entire index as "every sidecar vanished". `.notConfigured`
        // (plaintext) and `.unlocked` both proceed normally; only `.locked`
        // must no-op here, before any scan or mutation.
        //
        // The state check and the crypto used to build the scan store MUST
        // come from one atomic read. Reading `LibraryVaultProvider.shared.state`
        // and then separately calling `.fileStore()` (as this used to) is a
        // TOCTOU race: the vault can lock() between those two independent
        // awaits, so this could see `.unlocked` from the first read but get
        // `crypto == nil` from the second — a passthrough store built for a
        // container that is actually encrypted. `reconcileContext()` derives
        // both from one `LibraryVault.snapshot()` call with no suspension
        // point in between, so they can never disagree.
        let ctx = await LibraryVaultProvider.shared.reconcileContext()
        guard Self.shouldReconcile(givenVaultState: ctx.state) else {
            print("[LibraryIndex] vault is locked; skipping reconcile to preserve the index")
            return .didNotScan
        }
        let resolvedStartedAtGeneration: Int
        if let startedAtGeneration {
            resolvedStartedAtGeneration = startedAtGeneration
        } else {
            resolvedStartedAtGeneration = await generationProbe()
        }
        let startedAtGeneration = resolvedStartedAtGeneration
        // `ctx.store` is bound to the provider's own resolved directory (same
        // path as `itemsDirectory` in production, both from
        // `LibraryContainer.shared.itemsDirectory()`); tests pass their own
        // `itemsDirectory` here and must scan THAT directory, so only the
        // atomically-derived crypto is taken from `ctx.store` — the caller-
        // supplied directory is otherwise unchanged from before this fix.
        let store = LibraryFileStore(itemsDirectory: itemsDirectory, crypto: ctx.store.crypto)

        // The scan is a point-in-time snapshot of the container, read off the
        // actor. Direct mutations (add-to-album, saves, deletes) can land while
        // it is in flight; applying the snapshot then would overwrite the newer
        // index rows with pre-mutation data — e.g. resurrecting just-filed items
        // in "Not in any Album" until the next reconcile healed them. Capture
        // the mutation epoch before each scan and rescan if it moved. Bounded:
        // every epoch bump corresponds to a container file change, which
        // re-fires the metadata query and schedules another reconcile, so
        // giving up here never strands the index.
        for _ in 0..<3 {
            let epoch = currentMutationEpoch()
            // Read on the model actor, before the scan suspends: these are what
            // let the scan recognize an evicted encrypted file as belonging to a
            // row that still exists (see `scanContainer`'s placeholder branch).
            // Encrypted only — plaintext recovers the id from the `{id}.json`
            // stem and needs no help, so it shouldn't pay for the fetch.
            let known = store.isEncrypted ? indexedIDs() : (items: Set<Int>(), albums: Set<UUID>())
            // Task 4: read on the model actor, before the scan suspends —
            // the scan itself must never reach into SwiftData. Empty when
            // `rebuild` called this (`useFingerprints == false`), so every
            // sidecar is re-read unconditionally.
            let fingerprints = useFingerprints ? indexedFingerprints() : [:]
            let scan = await Self.runScan(
                store: store,
                indexedItemIDs: known.items,
                indexedAlbumIDs: known.albums,
                isPlaceholder: isPlaceholder,
                fingerprints: fingerprints
            )

            // A nil scan means the directory read *threw* (transient iCloud/filesystem
            // error). Treating that as "empty" would prune the whole index, so we
            // skip reconcile entirely and leave the index intact. A successfully-read
            // but empty directory still prunes normally — that's a legitimate
            // "every sidecar is gone" and the suite's reconcileDropsRowsWhoseSidecarVanished
            // depends on it.
            guard let scan else {
                print("[LibraryIndex] container unreadable; skipping reconcile to preserve the index")
                return .didNotScan
            }

            // The root may have been switched while this scan ran on its own
            // queue. Applying it now would write the OLD root's contents into
            // the NEW root's index and prune everything else.
            guard Self.shouldApplyScan(
                startedAtGeneration: startedAtGeneration,
                currentGeneration: await generationProbe()
            ) else {
                print("[LibraryIndex] Library root changed during the scan; discarding it")
                return .didNotScan
            }

            if case .applied(let albumStateChanged) = applyScan(scan, ifEpochMatches: epoch) {
                return ReconcileOutcome(
                    albumStateChanged: albumStateChanged,
                    pendingItems: scan.pendingItems,
                    pendingAlbums: scan.pendingAlbums
                )
            }
            print("[LibraryIndex] direct write landed during the container scan; rescanning")
        }
        print("[LibraryIndex] reconcile skipped: direct writes kept landing during scans")
        return .didNotScan
    }

    /// Pure decision extracted from `reconcile` so it's directly unit-testable
    /// without touching the `LibraryVaultProvider.shared` singleton: only a
    /// configured-but-locked vault blocks a reconcile/rebuild. `.notConfigured`
    /// (plaintext, today's only shipped mode) and `.unlocked` both proceed.
    nonisolated static func shouldReconcile(givenVaultState state: LibraryVault.State) -> Bool {
        state != .locked
    }

    /// Pure decision extracted so it is directly unit-testable: a scan may only
    /// be applied to the index if the Library root hasn't changed since the scan
    /// started.
    ///
    /// Scans run on `scanQueue`, off the model actor, so a root switch cannot
    /// cancel one already in flight. Without this check, a scan of the OLD root
    /// finishing after the switch would be applied to the NEW root's index and
    /// prune every row it never saw — the "I didn't see the files, therefore
    /// they're gone" failure this codebase has hit before with evicted iCloud
    /// containers.
    nonisolated static func shouldApplyScan(
        startedAtGeneration: Int,
        currentGeneration: Int
    ) -> Bool {
        startedAtGeneration == currentGeneration
    }

    /// Applies a completed scan to the index — unless a direct mutation landed
    /// after `epoch` was captured, in which case the snapshot is stale and is
    /// rejected (`.rejectedStaleEpoch`; the caller rescans). Internal rather than
    /// private so tests can drive the write-during-scan race deterministically.
    func applyScan(_ scan: ScanResult, ifEpochMatches epoch: Int) -> ScanApplication {
        guard currentMutationEpoch() == epoch else { return .rejectedStaleEpoch }

        // Fast path: upsert everything from an in-memory map and save once
        // (one query + one save instead of N + N). If that batched save throws,
        // fall back to a resilient per-item pass — a single all-or-nothing save
        // that silently failed is exactly what stranded the whole index empty
        // after a rebuild, so one poison row must never lose the other 1024.
        if let albumStateChanged = reconcileBatched(scan) {
            return .applied(albumStateChanged: albumStateChanged)
        }
        print("[LibraryIndex] batched reconcile save failed; retrying per-item")
        modelContext.rollback()
        return .applied(albumStateChanged: reconcilePerItem(scan))
    }

    /// Upserts `PersistedAlbum` rows from the scan and prunes rows whose album
    /// file vanished. Pure in-memory work on the model context; caller saves.
    /// Returns whether any album row was inserted, updated, or deleted.
    private func applyAlbums(_ scan: ScanResult) -> Bool {
        var changed = false
        let existing = (try? modelContext.fetch(FetchDescriptor<PersistedAlbum>())) ?? []
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for file in scan.albums {
            if let row = byID[file.id] {
                if Self.apply(file, to: row) { changed = true }
            } else {
                let row = PersistedAlbum(file: file)
                modelContext.insert(row)
                byID[file.id] = row
                changed = true
            }
        }
        for row in existing where !scan.seenAlbumIDs.contains(row.id) {
            modelContext.delete(row)
            changed = true
        }
        return changed
    }

    /// One in-memory diff + a single batched save. Returns whether album-relevant
    /// state changed on success, or `nil` if the save failed.
    private func reconcileBatched(_ scan: ScanResult) -> Bool? {
        let existing = (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
        var byID = Dictionary(existing.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })

        var albumStateChanged = false
        for scannedItem in scan.items {
            let metadata = scannedItem.metadata
            let status = scannedItem.status
            if let row = byID[metadata.itemID] {
                if apply(metadata, downloadStatus: status,
                         sidecarFileName: scannedItem.sidecarFileName,
                         sidecarModifiedAt: scannedItem.sidecarModifiedAt,
                         sidecarByteSize: scannedItem.sidecarByteSize,
                         to: row) { albumStateChanged = true }
            } else {
                let row = PersistedLibraryItem(
                    metadata: metadata, downloadStatus: status,
                    sidecarFileName: scannedItem.sidecarFileName,
                    sidecarModifiedAt: scannedItem.sidecarModifiedAt,
                    sidecarByteSize: scannedItem.sidecarByteSize
                )
                modelContext.insert(row)
                byID[metadata.itemID] = row
                if !metadata.albumIDs.isEmpty { albumStateChanged = true }
            }
        }
        // Task 4: rows the scan skipped reading (unchanged fingerprint)
        // still need their download status refreshed — the fingerprint
        // covers the sidecar, not the media, so an iCloud eviction since the
        // last scan must still flip the badge even though nothing else
        // about the row changed. Every id here is already in `byID` (it
        // came from an existing, unpruned row) and disjoint from
        // `scan.items`, so this never races the loop above.
        //
        // Applied AFTER `scan.items` here, but BEFORE it in
        // `reconcilePerItem` below — deliberately not unified, since the
        // two ids sets (`scan.statusUpdates` and `scan.items`, both keyed
        // by itemID) are disjoint by construction: Phase A/B route each
        // sidecar to exactly one of "skipped" or "read", never both. Order
        // between disjoint writers is harmless either way.
        for update in scan.statusUpdates {
            byID[update.itemID]?.downloadStatus = update.status
        }
        for item in existing where !scan.seenIDs.contains(item.itemID) {
            if !item.albumIDsJoined.isEmpty { albumStateChanged = true }
            modelContext.delete(item)
        }
        if applyAlbums(scan) { albumStateChanged = true }
        do {
            try modelContext.save()
            return albumStateChanged
        } catch {
            print("[LibraryIndex] batched reconcile save threw (\(scan.items.count) sidecars): \(error)")
            return nil
        }
    }

    /// Slow, resilient recovery: save after every row so a single bad sidecar
    /// (or a constraint hiccup) is rolled back and skipped instead of taking the
    /// entire batch down with it. Only runs when the fast path's save failed.
    /// Returns whether album-relevant state changed (same contract as
    /// `reconcileBatched`'s success case).
    private func reconcilePerItem(_ scan: ScanResult) -> Bool {
        let existing = (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
        var byID = Dictionary(existing.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })

        var albumStateChanged = false
        for item in existing where !scan.seenIDs.contains(item.itemID) {
            if !item.albumIDsJoined.isEmpty { albumStateChanged = true }
            modelContext.delete(item)
            if (try? modelContext.save()) == nil { modelContext.rollback() }
        }
        // Task 4: same status-only refresh as `reconcileBatched`, saved
        // per-row to match this path's resilience contract (one bad row
        // must not take the others down with it).
        //
        // Applied BEFORE `scan.items` here, but AFTER it in
        // `reconcileBatched` above — see that loop's comment: the two id
        // sets are disjoint by construction, so the ordering difference
        // between the two reconcile paths is harmless.
        for update in scan.statusUpdates {
            guard let row = byID[update.itemID] else { continue }
            row.downloadStatus = update.status
            if (try? modelContext.save()) == nil { modelContext.rollback() }
        }
        for scannedItem in scan.items {
            let metadata = scannedItem.metadata
            let status = scannedItem.status
            let membershipChanged: Bool
            if let row = byID[metadata.itemID] {
                membershipChanged = apply(metadata, downloadStatus: status,
                                           sidecarFileName: scannedItem.sidecarFileName,
                                           sidecarModifiedAt: scannedItem.sidecarModifiedAt,
                                           sidecarByteSize: scannedItem.sidecarByteSize,
                                           to: row)
            } else {
                let row = PersistedLibraryItem(
                    metadata: metadata, downloadStatus: status,
                    sidecarFileName: scannedItem.sidecarFileName,
                    sidecarModifiedAt: scannedItem.sidecarModifiedAt,
                    sidecarByteSize: scannedItem.sidecarByteSize
                )
                modelContext.insert(row)
                byID[metadata.itemID] = row
                membershipChanged = !metadata.albumIDs.isEmpty
            }
            do {
                try modelContext.save()
                if membershipChanged { albumStateChanged = true }
            } catch {
                print("[LibraryIndex] skipping item \(metadata.itemID): \(error)")
                modelContext.rollback()
            }
        }
        // Albums are applied and saved as one batch even in the per-item path; the
        // only failure mode (a duplicate id) is already prevented by applyAlbums's
        // dictionary guard, so per-row saves aren't needed here.
        let albumRowsChanged = applyAlbums(scan)
        if (try? modelContext.save()) == nil {
            modelContext.rollback()
        } else if albumRowsChanged {
            albumStateChanged = true
        }
        return albumStateChanged
    }

    /// Reads the container off the model actor: walks the directory, reads and
    /// decodes every sidecar, and resolves each media file's download status.
    /// All blocking file I/O lives here, so it must only be called from a
    /// background task (never the main actor). `nonisolated` + `static` so it
    /// carries no actor isolation and the detached caller doesn't hop back.
    /// Result of an off-actor container scan: every readable sidecar paired with
    /// its media download status, plus the set of itemIDs seen (for pruning),
    /// plus every readable album file and the set of album ids seen (for album pruning).
    /// `pendingItems`/`pendingAlbums` count the files this scan SKIPPED because
    /// they are un-materialized iCloud placeholders — i.e. content the user owns
    /// but cannot see yet. The scan already makes that judgement per file to
    /// decide whether reading is safe; these just stop it being discarded, so
    /// the Library can report "still downloading" rather than presenting a
    /// partial container as the whole library.
    ///
    /// Deliberately NOT a count of evicted media (`*.b`): most media being
    /// evicted is this app's healthy steady state, so including it would pin the
    /// UI in a "downloading" state that never clears.
    typealias ScanResult = (
        items: [(
            metadata: LibraryItemMetadata,
            status: LibraryDownloadStatus,
            /// The sidecar's name and fingerprint (`contentModificationDate`,
            /// `fileSize`) as seen by THIS scan's directory listing — not a
            /// separate stat. Recorded so incremental reconcile (Task 4) can
            /// compare a later listing against these instead of re-reading.
            sidecarFileName: String,
            sidecarModifiedAt: Date?,
            sidecarByteSize: Int
        )],
        seenIDs: Set<Int>,
        albums: [LibraryAlbumFile],
        seenAlbumIDs: Set<UUID>,
        pendingItems: Int,
        pendingAlbums: Int,
        /// Task 4: a skipped sidecar's freshly-resolved download status.
        /// Status is free from the directory listing, so it's refreshed even
        /// for a row whose sidecar read was skipped — the fingerprint covers
        /// the sidecar, not the media, so an item whose media was evicted
        /// since the last scan must still get an updated badge. Applied to
        /// the existing row's `downloadStatus` only; nothing else about the
        /// row is touched.
        statusUpdates: [(itemID: Int, status: LibraryDownloadStatus)],
        /// The scan's own I/O metrics, exposed (not just logged) so a caller
        /// — chiefly tests — can verify a skip actually skipped the read,
        /// not just that the resulting row survived.
        metrics: ScanMetrics
    )

    /// Dedicated serial queue for the blocking container scan. Keeps the
    /// `Data(contentsOf:)` / FileProvider syscalls off the Swift concurrency
    /// cooperative pool (see `reconcile`). Serial, so overlapping reconciles
    /// can never block more than one thread.
    private static let scanQueue = DispatchQueue(
        label: "com.achatessoftware.diffusely.library.scan",
        qos: .utility
    )

    /// Runs `scanContainer` on `scanQueue` and suspends the caller until it
    /// finishes — without occupying a cooperative thread.
    nonisolated static func runScan(
        store: LibraryFileStore,
        indexedItemIDs: Set<Int> = [],
        indexedAlbumIDs: Set<UUID> = [],
        isPlaceholder: @escaping PlaceholderCheck = { isDatalessPlaceholder($0) },
        fingerprints: [String: (modifiedAt: Date?, size: Int, itemID: Int, mediaFileName: String)] = [:]
    ) async -> ScanResult? {
        await withCheckedContinuation { continuation in
            scanQueue.async {
                continuation.resume(returning: scanContainer(
                    store: store,
                    indexedItemIDs: indexedItemIDs,
                    indexedAlbumIDs: indexedAlbumIDs,
                    isPlaceholder: isPlaceholder,
                    fingerprints: fingerprints
                ))
            }
        }
    }

    /// Resource keys prefetched during directory enumeration so the per-file
    /// ubiquitous-status reads (`isDatalessPlaceholder`, `downloadStatus`) are
    /// served from the enumerated URL objects' caches. Without the prefetch,
    /// every `resourceValues` call is an individual blocking XPC round-trip to
    /// fileproviderd — ~13k per scan at a 6.5k-item library, which turned the
    /// launch reconcile into minutes of churn on macOS.
    nonisolated static let scanPrefetchKeys: [URLResourceKey] = [
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
        // Fingerprint fields for incremental reconcile (Task 4): prefetched
        // here so reading them per sidecar in Phase A is served from this
        // listing's cache, not a separate per-file stat.
        .contentModificationDateKey,
        .fileSizeKey
    ]

    /// Convenience for direct plaintext callers/tests that don't have a
    /// `LibraryFileStore` handy: builds a passthrough one (`crypto: nil`) over
    /// `itemsDirectory` and scans through it. Byte-identical to scanning that
    /// directory directly — plaintext mode never touches `crypto`.
    nonisolated static func scanContainer(itemsDirectory: URL) -> ScanResult? {
        scanContainer(store: LibraryFileStore(itemsDirectory: itemsDirectory, crypto: nil))
    }

    /// Injectable placeholder predicate. Production passes
    /// `isDatalessPlaceholder`, which reads live iCloud resource values off the
    /// real FileProvider; tests substitute a stub so the not-yet-materialized
    /// paths through the scan are reachable over a plain temp directory.
    typealias PlaceholderCheck = (URL) -> Bool

    /// One scan's I/O profile. Printed once per scan so a slow container can be
    /// diagnosed from the log without a profiler attached — the numbers that
    /// motivated this work came from a synthetic benchmark that disagreed with
    /// observed behaviour by more than 10x, and this is how that gets settled.
    struct ScanMetrics {
        var listingSeconds = 0.0
        var sidecarsRead = 0
        var readSeconds = 0.0
        var decodeSeconds = 0.0
        var statCount = 0
        var statSeconds = 0.0

        var description: String {
            String(
                format: "[LibraryIndex] scan: listing %.2fs | %d sidecars read in %.2fs (%.2f ms each) | decode %.2fs | %d stats in %.2fs",
                listingSeconds, sidecarsRead, readSeconds,
                sidecarsRead > 0 ? readSeconds * 1000 / Double(sidecarsRead) : 0,
                decodeSeconds, statCount, statSeconds
            )
        }
    }

    /// One sidecar the scan has classified but not yet read. Splitting
    /// classification from reading keeps every `seenIDs` preservation
    /// decision in one serial pass (Phase A) even though the actual read
    /// (Phase B) is a separate loop.
    private struct SidecarWork {
        /// The item id recovered during classification. Used as the key
        /// passed to `store.readMetadata(itemID:)`, and — if the read or
        /// decode fails — as the id preserved in `seenIDs` so the row isn't
        /// pruned as vanished.
        let itemID: Int
        /// The sidecar's name and fingerprint, captured in Phase A from the
        /// enumerated URL's already-prefetched resource values — no extra
        /// I/O. Carried into Phase B so it can be recorded on the resulting
        /// `ScanResult` item regardless of whether the read below succeeds.
        let sidecarFileName: String
        let sidecarModifiedAt: Date?
        let sidecarByteSize: Int
    }

    /// Reads the container through `store`: every readable item sidecar
    /// (`*.m` decrypted or `*.json` parsed, per `store.isEncrypted`) plus,
    /// separately, every readable album file. Plaintext album files are the
    /// existing `album-{uuid}.json` sitting alongside item sidecars, classified
    /// by name; encrypted album files are opaque `*.x` aux files with no name
    /// to classify by, so each is decrypted and an attempt is made to decode it
    /// as a `LibraryAlbumFile` — content that doesn't decode that way (e.g. a
    /// future sort-assistant-state aux file) is silently skipped, not an error.
    ///
    /// Deliberately does ONE `contentsOfDirectory` call for the whole scan —
    /// not one via this method plus another inside `store.enumerateMetadataFiles()`/
    /// `enumerateAuxFiles()` — because a second, separately-fetched listing
    /// wouldn't carry this call's prefetched resourceValues cache, reintroducing
    /// the per-file XPC round-trip this scan exists to avoid. `store.isMetadataFileName`/
    /// `isAuxFileName` classify names from the single listing captured here.
    ///
    /// Restructured into three phases to split classification from reading:
    /// Phase A (serial) walks the sidecar URLs and classifies each into an
    /// album, a preserved placeholder, or a queued `SidecarWork`; Phase B
    /// (serial) reads + decodes each queued entry; Phase C (serial)
    /// assembles the `ScanResult`. Every preservation decision
    /// (`seenIDs`/`seenAlbumIDs`, the pending counters, the album handling)
    /// happens in Phase A, exactly as before this split.
    ///
    /// Phase B was briefly run concurrently (bounded `OperationQueue`,
    /// width 8) on the theory that each read is an independent, latency-
    /// bound network round trip. Measured on the user's real network-
    /// mounted share, concurrency made it slightly WORSE: 612.24s wall vs
    /// 562.88s serial, with per-worker cost rising to ~489 ms/file (~61 ms
    /// effective — indistinguishable from the 69.06 ms/file serial
    /// baseline). Something below `store.readMetadata` — the file-
    /// coordination arbiter, or the kernel SMB client serializing on one
    /// connection — was already serializing the reads regardless of thread
    /// count, so the concurrency machinery bought nothing and was reverted;
    /// the phase split itself stays, since it is what makes Phase C's
    /// index-ordered assembly and Task 4's per-sidecar skip a small,
    /// reviewable diff instead of one tangled loop.
    nonisolated static func scanContainer(
        store: LibraryFileStore,
        indexedItemIDs: Set<Int> = [],
        indexedAlbumIDs: Set<UUID> = [],
        isPlaceholder: PlaceholderCheck = { isDatalessPlaceholder($0) },
        // Task 4: sidecar fingerprints the index already holds, keyed by
        // sidecar filename — read on the model actor by `reconcile` before
        // the scan starts (`indexedFingerprints()`) and handed in here so
        // Phase A can decide, per sidecar, whether reading it is necessary
        // at all. Empty (the default) means "never skip" — every existing
        // call site (tests, `rebuild`) that doesn't pass this gets the exact
        // pre-Task-4 always-read behavior.
        fingerprints: [String: (modifiedAt: Date?, size: Int, itemID: Int, mediaFileName: String)] = [:]
    ) -> ScanResult? {
        let fileManager = FileManager.default
        let itemsDirectory = store.itemsDirectory
        var metrics = ScanMetrics()
        let listingStart = CFAbsoluteTimeGetCurrent()
        guard let contents = try? fileManager.contentsOfDirectory(
            at: itemsDirectory,
            includingPropertiesForKeys: scanPrefetchKeys
        ) else {
            // Couldn't read the directory (transient iCloud/filesystem error).
            // Returning an empty scan would make reconcile prune the entire
            // index; signal failure so the caller leaves it intact instead.
            return nil
        }
        metrics.listingSeconds = CFAbsoluteTimeGetCurrent() - listingStart

        // Media files are looked up from the same enumeration: the returned
        // URL objects carry the prefetched status values, while a freshly
        // built `appendingPathComponent` URL has an empty cache and would XPC
        // to fileproviderd per file. Cached values are point-in-time, which is
        // exactly the snapshot semantics a scan wants; each scan re-enumerates
        // and gets fresh objects.
        var urlsByName = [String: URL](minimumCapacity: contents.count)
        for url in contents { urlsByName[url.lastPathComponent] = url }
        // Presence for every file this scan will look up is already known from
        // the single listing above — `downloadStatus` uses membership in this
        // set instead of a per-file `fileExists` round trip.
        let presentNames = Set(urlsByName.keys)

        var seenIDs = Set<Int>()
        var items: [(
            metadata: LibraryItemMetadata,
            status: LibraryDownloadStatus,
            sidecarFileName: String,
            sidecarModifiedAt: Date?,
            sidecarByteSize: Int
        )] = []
        var albums: [LibraryAlbumFile] = []
        var seenAlbumIDs = Set<UUID>()
        // Task 4: status refreshes for sidecars the scan chose not to read.
        var statusUpdates: [(itemID: Int, status: LibraryDownloadStatus)] = []
        // Counted independently of `seenIDs`: after an eviction sweep most
        // placeholders resolve to no known id (nothing is invented), yet those
        // are exactly the items missing from the user's library. A pending total
        // that only tallied recognized rows would report ~0 while thousands of
        // items were absent.
        var pendingItems = 0
        var pendingAlbums = 0

        // Reverse token maps are built at most once per scan, and only if an
        // evicted file is actually met — the common all-materialized scan pays
        // nothing, and a sweep-evicted container pays one HMAC per indexed id.
        var itemIDsByFileName: [String: Int]?
        func preservedItemID(_ url: URL) -> Int? {
            guard let crypto = store.crypto else { return sidecarItemID(from: url) }
            let map = itemIDsByFileName ?? metadataFileNames(forItemIDs: indexedItemIDs, crypto: crypto)
            itemIDsByFileName = map
            return map[url.lastPathComponent]
        }
        var albumIDsByFileName: [String: UUID]?
        func preservedAlbumID(_ url: URL) -> UUID? {
            guard let crypto = store.crypto else { return nil }
            let map = albumIDsByFileName ?? auxFileNames(forAlbumIDs: indexedAlbumIDs, crypto: crypto)
            albumIDsByFileName = map
            return map[url.lastPathComponent]
        }

        // Phase A (serial): classify every sidecar. Album files, placeholder
        // preservation, and the id-recovery guard are all unchanged from
        // before this split — the only thing that changed is that a
        // fully-classified item sidecar is queued as a `SidecarWork` instead
        // of being read+decoded inline.
        let sidecarURLs = contents.filter { store.isMetadataFileName($0.lastPathComponent) }
        var sidecarWork: [SidecarWork] = []
        for sidecarURL in sidecarURLs {
            let name = sidecarURL.lastPathComponent

            // Plaintext album metadata file: decode separately, never as an
            // item sidecar. An encrypted `*.m` name can never match this
            // prefix/suffix check (hex tokens can't start with "album-" and
            // don't end in ".json"), so this branch is a no-op in encrypted
            // mode; encrypted album rows come from the aux pass below instead.
            if let albumID = LibraryAlbumStore.albumID(fromFileName: name) {
                // The file's presence means the album exists — mark it seen up
                // front so a present-but-unreadable file (placeholder, transient
                // read error, or corrupt JSON) never prunes the row. Mirrors how
                // a not-yet-materialized item is kept via seenIDs.
                seenAlbumIDs.insert(albumID)
                if isPlaceholder(sidecarURL) {
                    try? fileManager.startDownloadingUbiquitousItem(at: sidecarURL)
                    pendingAlbums += 1
                    continue
                }
                // Decode best-effort: only a readable file refreshes name/createdAt.
                if let data = try? Data(contentsOf: sidecarURL),
                   let file = try? LibraryAlbumFile.decoder().decode(LibraryAlbumFile.self, from: data) {
                    albums.append(file)
                }
                continue
            }

            // Item sidecar.
            // A sidecar whose bytes aren't materialized locally is an iCloud
            // placeholder; reading it (plaintext `Data(contentsOf:)`, or an
            // encrypted read via the store) would force a synchronous
            // FileProvider download that can block for a long time. Request a
            // non-blocking download instead and preserve the item by recovering
            // its id WITHOUT reading the file, so reconcile doesn't prune the row
            // as "vanished" — a later reconcile (the metadata query fires when the
            // file materializes) ingests its fields. Plaintext reads the id off
            // the `{id}.json` stem; encrypted matches the opaque token against the
            // ids the index already holds (see `metadataFileNames(forItemIDs:)`).
            // Getting this wrong is not a cosmetic miss: macOS evicts iCloud
            // content in sweeps, so a sweep over the container turned every
            // sidecar into a placeholder at once and pruned the ENTIRE index,
            // which then rebuilt file-by-file as the sidecars re-downloaded.
            if isPlaceholder(sidecarURL) {
                try? fileManager.startDownloadingUbiquitousItem(at: sidecarURL)
                pendingItems += 1
                if let id = preservedItemID(sidecarURL) {
                    seenIDs.insert(id)
                }
                continue
            }

            // Cache-only: `sidecarURL` came from the single `contentsOfDirectory`
            // listing above, which already prefetched these two keys via
            // `scanPrefetchKeys`, so this is not a per-file XPC round trip.
            let fingerprint = try? sidecarURL.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey])
            let observedModifiedAt = fingerprint?.contentModificationDate
            let observedByteSize = fingerprint?.fileSize ?? 0

            // Task 4: checked BEFORE `store.itemID(forMetadataFile:)` below —
            // deliberately, not just for tidiness. In encrypted mode that
            // call performs its own full coordinated read+decrypt of the
            // sidecar (to decode the `{itemID}` stub), which is exactly the
            // network round trip this skip exists to avoid. A name+fingerprint
            // match against the index needs no file read at all to recover
            // the id — it's already sitting in the fingerprint map recorded
            // by the scan that ingested it.
            //
            // `knownModifiedAt` must be non-nil to match anything: a row
            // whose prior scan couldn't stat the file (the partial-
            // fingerprint case) recorded `sidecarModifiedAt == nil`, and nil
            // must never be treated as "matches whatever we see now". Any
            // mismatch on either field falls through to a normal read — the
            // fingerprint can be legitimately stale (Phase A captures it,
            // Phase B reads later, so a file modified in that window is
            // recorded pre-change) and a stale-but-different fingerprint is
            // meant to force a re-read, never a wrong skip.
            if let known = fingerprints[name],
               let knownModifiedAt = known.modifiedAt,
               knownModifiedAt == observedModifiedAt,
               known.size == observedByteSize {
                // Unchanged since we last ingested it. Skip the READ, but the
                // file is present, so the id must still be seen or reconcile
                // prunes the row. Status is free from the listing, so refresh
                // it anyway: the fingerprint covers the sidecar, not the
                // media, and an evicted media file must still update the
                // badge.
                seenIDs.insert(known.itemID)
                // The extension comes from the row's own stored
                // `mediaFileName` — the value the index already has —
                // instead of a per-scan guess built by listing every
                // non-sidecar file and taking the last extension seen for
                // each id. That guess was last-write-wins over an
                // unordered listing: an item with both a stale `{id}.jpeg`
                // and a current `{id}.mp4` present (a state the encryption
                // migrator treats as real) could take its badge from the
                // wrong file, and because this item is skipped on every
                // later scan too, it would never self-heal. `store.mediaURL`
                // ignores the extension entirely in encrypted mode, so this
                // is correct there regardless.
                let mediaURL = store.mediaURL(
                    itemID: known.itemID,
                    plaintextExtension: URL(fileURLWithPath: known.mediaFileName).pathExtension)
                let lookupURL = urlsByName[mediaURL.lastPathComponent] ?? mediaURL
                let statStart = CFAbsoluteTimeGetCurrent()
                let status = downloadStatus(for: lookupURL, fileManager: fileManager, presentNames: presentNames)
                // Task 4 correction: this branch resolves a real status from
                // the listing for every skipped sidecar, but originally
                // never counted it — an unchanged launch printed "0 stats"
                // while actually resolving one per row. Count it like any
                // other stat.
                metrics.statSeconds += CFAbsoluteTimeGetCurrent() - statStart
                metrics.statCount += 1
                statusUpdates.append((itemID: known.itemID, status: status))
                continue
            }

            // A file that is present but can't be read or decoded THIS round —
            // a torn write, a failed coordination, corrupt bytes — has not
            // vanished, so it must not prune its row either. Same rule the
            // album branch above already applies, and the same no-I/O id
            // recovery the placeholder branch uses. A later reconcile ingests
            // its fields once the file reads cleanly again.
            guard let id = store.itemID(forMetadataFile: sidecarURL) else {
                if let id = preservedItemID(sidecarURL) {
                    seenIDs.insert(id)
                }
                continue
            }

            sidecarWork.append(SidecarWork(
                itemID: id,
                sidecarFileName: name,
                sidecarModifiedAt: observedModifiedAt,
                sidecarByteSize: observedByteSize
            ))
        }

        // Phase B (serial): read + decode each queued item sidecar and
        // resolve its media download status. See this function's doc
        // comment for why this is serial rather than concurrent — a bounded
        // `OperationQueue` was measured on the real network share to be
        // slightly worse than this loop, not faster.
        for work in sidecarWork {
            let id = work.itemID

            let readStart = CFAbsoluteTimeGetCurrent()
            let data = store.readMetadata(itemID: id)
            metrics.readSeconds += CFAbsoluteTimeGetCurrent() - readStart
            guard let data else {
                // Present but unreadable this round (transient coordination
                // failure, torn write): not vanished, so the row must be
                // preserved rather than pruned, using the id Phase A already
                // recovered for this exact sidecar.
                seenIDs.insert(id)
                continue
            }
            metrics.sidecarsRead += 1

            let decodeStart = CFAbsoluteTimeGetCurrent()
            let metadata = try? LibraryItemMetadata.decoder().decode(LibraryItemMetadata.self, from: data)
            metrics.decodeSeconds += CFAbsoluteTimeGetCurrent() - decodeStart
            guard let metadata else {
                seenIDs.insert(id)
                continue
            }

            seenIDs.insert(metadata.itemID)
            // The store's deterministic media URL for this item — identical
            // to `itemsDirectory.appendingPathComponent(metadata.mediaFileName)`
            // in plaintext mode (that's exactly how `mediaFileName` was
            // built at save time), and the correct opaque `*.b` path when
            // encrypted. Missing from the listing (no local placeholder at
            // all) falls back to the built URL, whose name `downloadStatus`
            // won't find in `presentNames` — resolves to `.evicted`, same
            // result as before, no XPC needed.
            let mediaURL = store.mediaURL(itemID: metadata.itemID, plaintextExtension: metadata.mediaType.fileExtension)
            let lookupURL = urlsByName[mediaURL.lastPathComponent] ?? mediaURL
            let statStart = CFAbsoluteTimeGetCurrent()
            let status = downloadStatus(for: lookupURL, fileManager: fileManager, presentNames: presentNames)
            metrics.statSeconds += CFAbsoluteTimeGetCurrent() - statStart
            metrics.statCount += 1
            items.append((
                metadata: metadata,
                status: status,
                sidecarFileName: work.sidecarFileName,
                sidecarModifiedAt: work.sidecarModifiedAt,
                sidecarByteSize: work.sidecarByteSize
            ))
        }

        // Encrypted album rows: album files (and, once routed through the
        // store, sort-assistant state) share the opaque `.x` namespace with no
        // filename hint, so classify by attempting to decode each as a
        // `LibraryAlbumFile` — content that doesn't decode that way is skipped.
        if store.isEncrypted {
            let auxURLs = contents.filter { store.isAuxFileName($0.lastPathComponent) }
            for auxURL in auxURLs {
                if isPlaceholder(auxURL) {
                    try? fileManager.startDownloadingUbiquitousItem(at: auxURL)
                    // An evicted `.x` blob is opaque: album file and
                    // sort-assistant state are indistinguishable without
                    // reading it, so this can overcount albums by the number of
                    // evicted non-album aux files (currently at most one). The
                    // alternative — counting only tokens matching a known album
                    // id — would undercount exactly when it matters most, on a
                    // container whose album rows haven't been ingested yet.
                    pendingAlbums += 1
                    // Same preservation as an evicted item sidecar: an album row
                    // whose file is merely not materialized has not vanished.
                    if let id = preservedAlbumID(auxURL) {
                        seenAlbumIDs.insert(id)
                    }
                    continue
                }
                // Unreadable-or-undecodable splits two ways here, and only the
                // token can tell them apart: an aux file matching a known album
                // id is that album's file and its row is preserved; anything
                // else is either a non-album aux blob (sort-assistant state,
                // which decodes as nothing and owns no row) or an album this
                // index never had — both correctly skipped.
                guard
                    let data = store.readAux(at: auxURL),
                    let file = try? LibraryAlbumFile.decoder().decode(LibraryAlbumFile.self, from: data)
                else {
                    if let id = preservedAlbumID(auxURL) {
                        seenAlbumIDs.insert(id)
                    }
                    continue
                }
                albums.append(file)
                seenAlbumIDs.insert(file.id)
            }
        }

        FileHandle.standardError.write(Data((metrics.description + "\n").utf8))
        return (items: items, seenIDs: seenIDs, albums: albums, seenAlbumIDs: seenAlbumIDs,
                pendingItems: pendingItems, pendingAlbums: pendingAlbums,
                statusUpdates: statusUpdates, metrics: metrics)
    }

    /// True when `url` is an iCloud item whose contents are not yet downloaded —
    /// reading it would force a blocking FileProvider materialization. Mirrors the
    /// status check in `downloadStatus(for:fileManager:)`. A non-ubiquitous local
    /// file returns `false` (safe to read directly).
    nonisolated static func isDatalessPlaceholder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ])
        guard values?.isUbiquitousItem == true else { return false }
        switch values?.ubiquitousItemDownloadingStatus {
        case .some(.current), .some(.downloaded):
            return false   // bytes are present locally
        default:
            return true    // placeholder; not yet materialized
        }
    }

    /// Sidecars are named `{itemID}.json`, so the item ID is recoverable from the
    /// filename without reading the (possibly not-yet-downloaded) contents.
    nonisolated static func sidecarItemID(from jsonURL: URL) -> Int? {
        Int(jsonURL.deletingPathExtension().lastPathComponent)
    }

    /// Encrypted counterpart of `sidecarItemID`: `{opaque metadata file name:
    /// itemID}` for every id the index already holds.
    ///
    /// An encrypted filename is `HMAC(fileKey, "meta:{itemID}")` — not
    /// invertible, which is why an evicted encrypted sidecar used to be
    /// unidentifiable and its row pruned. But it doesn't need inverting: the
    /// token is deterministic, so recomputing it FORWARDS for each already-known
    /// id yields the same reverse lookup, with no file read and therefore no
    /// blocking FileProvider download — exactly the property plaintext gets for
    /// free from its `{itemID}.json` stem.
    nonisolated static func metadataFileNames(forItemIDs ids: Set<Int>, crypto: LibraryFileCrypto) -> [String: Int] {
        var map = [String: Int](minimumCapacity: ids.count)
        for id in ids { map[crypto.fileName(itemID: id, role: .meta)] = id }
        return map
    }

    /// Album counterpart of `metadataFileNames(forItemIDs:crypto:)`. Keyed on the
    /// same logical name `LibraryAlbumStore` writes through (`album-{uuid}.json`),
    /// so the token matches the one actually on disk. Aux files that are not
    /// albums (sort-assistant state) match nothing here — correctly, since there
    /// is no album row of theirs to preserve.
    nonisolated static func auxFileNames(forAlbumIDs ids: Set<UUID>, crypto: LibraryFileCrypto) -> [String: UUID] {
        var map = [String: UUID](minimumCapacity: ids.count)
        for id in ids { map[crypto.fileName(auxName: LibraryAlbumStore.fileName(for: id))] = id }
        return map
    }

    /// Rebuilds the index from the container. Despite the name this no longer
    /// wipes-then-reinserts: deleting every row and immediately re-inserting new
    /// objects with the *same* `@Attribute(.unique) itemID` values on this one
    /// `@ModelActor` context (within the same session) made the re-insert `save()`
    /// throw a unique-constraint violation — the uniquing index still carried the
    /// just-deleted keys — which `try?` then swallowed, stranding the store empty.
    /// `reconcile` already re-reads every sidecar, re-applies all mutable fields
    /// (healing field-level corruption), inserts brand-new sidecars, and deletes
    /// rows whose sidecar has vanished. That is a full rebuild from the source of
    /// truth, without the destructive empty window or the re-insert hazard.
    @discardableResult
    func rebuild(
        itemsDirectory: URL,
        startedAtGeneration: Int? = nil,
        generationProbe: @Sendable @escaping () async -> Int = {
            await LibraryContainer.shared.rootGeneration
        }
    ) async -> ReconcileOutcome {
        await reconcile(itemsDirectory: itemsDirectory,
                        startedAtGeneration: startedAtGeneration,
                        generationProbe: generationProbe,
                        useFingerprints: false)
    }

    /// Deletes every index row without reconciling. Used by Reset Library after
    /// the container files themselves have been deleted.
    func wipe() {
        bumpMutationEpoch()
        let existing = (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
        for item in existing { modelContext.delete(item) }
        try? modelContext.save()
    }

    func itemCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<PersistedLibraryItem>())) ?? 0
    }

    /// Everything `LibraryStore.refreshTotals()` needs after a reconcile, read
    /// in ONE full-table pass instead of the two separate fetches
    /// (`itemCount()` + `totalDownloadedBytes()`) it used to make. The saved-ID
    /// set — which backs the feed's "already in your library" badge — therefore
    /// costs no additional query: it's derived from rows this pass already
    /// materialized. `itemCount()` / `totalDownloadedBytes()` remain for callers
    /// that want just one number.
    struct IndexSummary {
        let itemCount: Int
        let downloadedBytes: Int
        /// Every indexed item's Civitai image id — the same value a feed item
        /// carries as `CivitaiImage.id`, so membership is an exact match, not a
        /// heuristic.
        let savedItemIDs: Set<Int>
    }

    /// The ids the index currently holds. Handed to `scanContainer` so an
    /// evicted encrypted file — whose opaque name is a one-way HMAC — can still
    /// be matched back to the row it belongs to and preserved rather than pruned.
    func indexedIDs() -> (items: Set<Int>, albums: Set<UUID>) {
        // Ids only: reconcile already fetches these tables in full to diff them,
        // and this runs first, so pulling whole rows here would roughly double
        // the fetch cost of every reconcile on a large library.
        var itemsDescriptor = FetchDescriptor<PersistedLibraryItem>()
        itemsDescriptor.propertiesToFetch = [\.itemID]
        var albumsDescriptor = FetchDescriptor<PersistedAlbum>()
        albumsDescriptor.propertiesToFetch = [\.id]
        let items = (try? modelContext.fetch(itemsDescriptor)) ?? []
        let albums = (try? modelContext.fetch(albumsDescriptor)) ?? []
        return (Set(items.map(\.itemID)), Set(albums.map(\.id)))
    }

    /// Every indexed row's sidecar fingerprint, keyed by sidecar filename —
    /// what Task 4's incremental reconcile compares a fresh directory
    /// listing against to decide whether a sidecar needs to be re-read. Read
    /// on the model actor BEFORE the scan starts; the scan itself (running
    /// off the actor) must never reach into SwiftData. Rows with an empty
    /// `sidecarFileName` (pre-Task-3 rows, or ones written through a
    /// non-scan path like `ingest`) contribute nothing — an empty key can't
    /// match any real listing entry, so those rows always fall through to a
    /// read, exactly like a row with no recorded fingerprint should.
    ///
    /// This deliberately makes the returned id set a SUBSET of
    /// `indexedIDs()`'s — every row is present in `indexedIDs()`, but a
    /// row with no fingerprint yet contributes nothing here. Anyone tempted
    /// to merge this with `indexedIDs()` into one whole-table fetch to save
    /// a query must preserve that asymmetry, or an encrypted placeholder row
    /// (indexed, but never fingerprinted because it has never been read)
    /// would silently start being treated as fingerprint-known.
    func indexedFingerprints() -> [String: (modifiedAt: Date?, size: Int, itemID: Int, mediaFileName: String)] {
        // Same shape as `indexedIDs()`: only the columns the comparison
        // actually needs, not full rows, since this also runs over the
        // whole table every reconcile.
        var descriptor = FetchDescriptor<PersistedLibraryItem>()
        descriptor.propertiesToFetch = [\.itemID, \.sidecarFileName, \.sidecarModifiedAt, \.sidecarByteSize, \.mediaFileName]
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        var map = [String: (modifiedAt: Date?, size: Int, itemID: Int, mediaFileName: String)](minimumCapacity: rows.count)
        for row in rows where !row.sidecarFileName.isEmpty {
            map[row.sidecarFileName] = (
                modifiedAt: row.sidecarModifiedAt, size: row.sidecarByteSize,
                itemID: row.itemID, mediaFileName: row.mediaFileName
            )
        }
        return map
    }

    /// Every indexed id, plus `itemID` → `checkpointName` for the rows that
    /// have one. Read-only, ids/names only for the same reason `indexedIDs`
    /// fetches ids only: this runs over the whole table.
    ///
    /// Both come from ONE fetch, and the id set is returned alongside the
    /// names rather than left implicit, because `LibraryCheckpointDiagnostics`
    /// must tell "no row yet" apart from "row present, no name" — the names
    /// map alone conflates them, and only the second is index drift.
    func checkpointIndexSnapshot() -> (ids: Set<Int>, names: [Int: String]) {
        var descriptor = FetchDescriptor<PersistedLibraryItem>()
        descriptor.propertiesToFetch = [\.itemID, \.checkpointName]
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        var ids = Set<Int>(minimumCapacity: rows.count)
        var names: [Int: String] = [:]
        for row in rows {
            ids.insert(row.itemID)
            guard let name = row.checkpointName, !name.isEmpty else { continue }
            names[row.itemID] = name
        }
        return (ids, names)
    }

    func summary() -> IndexSummary {
        let items = (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
        var downloadedBytes = 0
        var ids = Set<Int>(minimumCapacity: items.count)
        for item in items {
            ids.insert(item.itemID)
            if item.downloadStatus == .downloaded { downloadedBytes += item.fileByteSize }
        }
        return IndexSummary(itemCount: items.count, downloadedBytes: downloadedBytes, savedItemIDs: ids)
    }

    /// Flat sizing rows for the macOS Library export's pre-flight plan. Reads
    /// the whole table once, like `summary()` — the export is a rare,
    /// user-initiated operation, so a single full fetch is cheaper and simpler
    /// than a predicate-narrowed query.
    func exportSizingRows() -> [LibraryExportSizingRow] {
        let items = (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
        return items.map {
            LibraryExportSizingRow(
                itemID: $0.itemID,
                mediaFileName: $0.mediaFileName,
                fileByteSize: $0.fileByteSize,
                isEvicted: $0.downloadStatus != .downloaded)
        }
    }

    // MARK: - LRU eviction

    func totalDownloadedBytes() -> Int {
        let items = (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
        return items
            .filter { $0.downloadStatus == .downloaded }
            .reduce(0) { $0 + $1.fileByteSize }
    }

    /// Evicts least-recently-accessed media until the downloaded total is at or
    /// below `maxBytes`. Sidecar JSON is never evicted. Cooperative, not exact -
    /// iCloud may also evict independently.
    /// Convenience for plaintext callers/tests without a store handy — builds a
    /// passthrough one, byte-identical to evicting `{id}.{ext}` directly. An
    /// encrypted container MUST go through `enforceCacheLimit(maxBytes:store:)`
    /// with the real store, or eviction aims at names that aren't on disk.
    func enforceCacheLimit(maxBytes: Int, itemsDirectory: URL) async {
        await enforceCacheLimit(
            maxBytes: maxBytes,
            store: LibraryFileStore(itemsDirectory: itemsDirectory, crypto: nil)
        )
    }

    func enforceCacheLimit(maxBytes: Int, store: LibraryFileStore) async {
        guard maxBytes > 0 else { return }
        let downloaded = ((try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? [])
            .filter { $0.downloadStatus == .downloaded }
        var total = downloaded.reduce(0) { $0 + $1.fileByteSize }
        guard total > maxBytes else { return }

        // Pick least-recently-accessed victims down to the limit. Pure read of
        // index state — we only need the filenames for the file I/O below.
        var victimIDs: [Int] = []
        var victims: [(itemID: Int, plaintextExtension: String)] = []
        for item in downloaded.sorted(by: { $0.lastAccessedAt < $1.lastAccessedAt }) {
            if total <= maxBytes { break }
            victimIDs.append(item.itemID)
            victims.append((
                itemID: item.itemID,
                plaintextExtension: URL(fileURLWithPath: item.mediaFileName).pathExtension
            ))
            total -= item.fileByteSize
        }
        guard !victimIDs.isEmpty else { return }

        // `evictUbiquitousItem` is a blocking XPC round-trip to fileproviderd.
        // Run every eviction on a dedicated serial queue (NOT `Task.detached`,
        // which stays on the Swift concurrency cooperative pool: a blocking
        // syscall there burns a cooperative thread and, under iCloud churn,
        // starves the pool — the documented "grey spinner" regression). The
        // queue also keeps the work off the model actor, which serializes all
        // index reads/writes, so a slow or unresponsive daemon can't wedge it
        // and beachball the whole app (it did, at ~1k items). Only the SwiftData
        // status flip below touches the actor.
        await Self.runEvictMedia(victims: victims, store: store)

        // Re-fetch after the suspension (the actor is reentrant — another call
        // may have run while we awaited), then flip the evicted rows and save
        // once.
        let evicted = Set(victimIDs)
        let rows = (try? modelContext.fetch(FetchDescriptor<PersistedLibraryItem>())) ?? []
        for item in rows where evicted.contains(item.itemID) {
            item.downloadStatus = .evicted
        }
        try? modelContext.save()
    }

    func evictAllDownloaded(itemsDirectory: URL) async {
        await enforceCacheLimit(maxBytes: 1, itemsDirectory: itemsDirectory)
    }

    func evictAllDownloaded(store: LibraryFileStore) async {
        await enforceCacheLimit(maxBytes: 1, store: store)
    }

    /// Dedicated serial queue for the blocking coordinated evictions below. Keeps
    /// the synchronous `NSFileCoordinator` + `FileManager.evictUbiquitousItem`
    /// syscalls (eviction is a blocking XPC round-trip to fileproviderd) off the
    /// Swift concurrency cooperative pool — running them on `Task.detached` or
    /// any `async` context would burn cooperative threads and starve the pool,
    /// the documented "grey spinner" regression. Serial + utility QoS mirrors
    /// `scanQueue` and `LibraryStore.deleteQueue`.
    private static let evictionQueue = DispatchQueue(
        label: "com.achatessoftware.diffusely.library.eviction",
        qos: .utility
    )

    /// Coordinates eviction of the named media files in `dir`. `nonisolated` so
    /// it carries no actor isolation; the synchronous file coordination must run
    /// on `evictionQueue`, never the main actor or the model actor. Missing files
    /// are tolerated (eviction is a no-op / swallowed error).
    /// The media file each victim actually occupies on disk. Resolved through
    /// `store`, NOT from the sidecar's `mediaFileName`: that field records the
    /// plaintext `{itemID}.{ext}` name, which in an encrypted container names no
    /// file at all — the media lives under the opaque `{token}.b`. Evicting the
    /// plaintext name there is a silent no-op, so the cache limit frees nothing
    /// and the container grows past it until macOS evicts the whole thing itself,
    /// sidecars included. Mirrors how the scan resolves media status.
    nonisolated static func mediaURLsToEvict(
        victims: [(itemID: Int, plaintextExtension: String)],
        store: LibraryFileStore
    ) -> [URL] {
        victims.map { store.mediaURL(itemID: $0.itemID, plaintextExtension: $0.plaintextExtension) }
    }

    nonisolated static func evictMedia(victims: [(itemID: Int, plaintextExtension: String)], store: LibraryFileStore) {
        let coordinator = NSFileCoordinator()
        for mediaURL in mediaURLsToEvict(victims: victims, store: store) {
            var coordinationError: NSError?
            coordinator.coordinate(
                writingItemAt: mediaURL,
                options: .forDeleting,
                error: &coordinationError
            ) { url in
                try? FileManager.default.evictUbiquitousItem(at: url)
            }
        }
    }

    /// Runs `evictMediaFiles` on `evictionQueue` and suspends the caller until it
    /// finishes — without occupying a cooperative thread or the model actor.
    nonisolated static func runEvictMedia(
        victims: [(itemID: Int, plaintextExtension: String)],
        store: LibraryFileStore
    ) async {
        await withCheckedContinuation { continuation in
            evictionQueue.async {
                evictMedia(victims: victims, store: store)
                continuation.resume()
            }
        }
    }

    // MARK: - Helpers

    private func fetchItem(itemID: Int) -> PersistedLibraryItem? {
        var descriptor = FetchDescriptor<PersistedLibraryItem>(
            predicate: #Predicate { $0.itemID == itemID }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// `presentNames`, when supplied, is the set of filenames from a single
    /// directory listing (`scanContainer`'s `urlsByName` keys) — membership in
    /// it replaces the `fileExists` round trip. That matters because the
    /// listing prefetches resource values onto its URL objects, but
    /// `fileExists(atPath:)` bypasses that cache and issues a fresh metadata
    /// XPC call to fileproviderd per file (measured at 26.91 ms/file, 219s
    /// across 8,151 items on a network-mounted iCloud root — 27.8% of the
    /// whole scan). `nil` (every caller besides `scanContainer`) preserves the
    /// original `fileExists` behaviour exactly, byte-for-byte.
    static func downloadStatus(
        for mediaURL: URL, fileManager: FileManager, presentNames: Set<String>? = nil
    ) -> LibraryDownloadStatus {
        let isPresent = presentNames?.contains(mediaURL.lastPathComponent)
            ?? fileManager.fileExists(atPath: mediaURL.path)
        guard isPresent else {
            // No local placeholder at all - treat as evicted; on-demand download
            // will materialize it when the user opens the item.
            return .evicted
        }
        let values = try? mediaURL.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ])
        if values?.isUbiquitousItem == true {
            switch values?.ubiquitousItemDownloadingStatus {
            case .some(.current), .some(.downloaded):
                return .downloaded
            default:
                return .evicted
            }
        }
        // Non-ubiquitous local file (local-only fallback) that exists = downloaded.
        return .downloaded
    }
}
