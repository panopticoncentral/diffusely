import Foundation

/// Orchestrates a Library root switch, mirroring `LibraryEncryptionCoordinator`:
/// one @MainActor type owning a sequence whose ORDER is the contract.
///
/// Quiesce and the generation bump precede the flip so no trigger fires against
/// a root that is moving; the wipe precedes the rebuild so the index never mixes
/// two roots. An in-flight scan cannot be cancelled — it is neutralised instead
/// by the generation counter (`LibraryIndexService.shouldApplyScan`).
@MainActor
final class LibraryRootCoordinator: ObservableObject {
    /// What the index rebuild against the NEW root actually did.
    ///
    /// The distinction that matters is between the two ways a rebuild can scan
    /// nothing. The index has just been wiped, so "scanned nothing" cannot
    /// simply be reported as success — but neither can it simply be reported as
    /// failure, because a locked vault is the CORRECT, expected outcome of
    /// switching back to an encrypted iCloud Library.
    enum RebuildOutcome: Equatable {
        /// The rebuild scanned the new root and applied its results.
        case scanned
        /// Nothing was scanned because the new root's vault is locked. This is
        /// a SUCCESSFUL switch to an encrypted iCloud Library: the gate settles
        /// on `.locked` and the user unlocks exactly as they would at launch.
        case lockedVault
        /// Nothing was scanned for any other reason — an unreadable container,
        /// a generation that moved. The index has just been wiped, so treating
        /// this as success would leave the user browsing an empty Library and
        /// call it a completed switch. Carries the path that failed.
        case failed(URL)
    }

    struct Dependencies {
        var validate: (URL) async -> LibraryRootError?
        var beginSwitch: () -> Void
        var quiesce: () async -> Void
        /// Persists the root, clears the cached directory and bumps the
        /// generation — `LibraryContainer.setRoot` does all three.
        var applyRoot: (LibraryRoot) async throws -> Void
        var rebootstrapVault: () async -> Void
        var wipeIndex: () async -> Void
        var rebuildIndex: () async throws -> RebuildOutcome
        var restartStore: () async -> Void
        var endSwitch: () async -> Void
        /// `nil` when the failure names no folder of the user's — see
        /// `LibraryVaultProvider.LibraryGate.rootUnavailable`.
        var reportUnavailable: (URL?) -> Void
    }

    @Published private(set) var isSwitching = false

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    @discardableResult
    func switchTo(_ root: LibraryRoot) async -> LibraryRootError? {
        // Re-entrancy guard: `switchTo` suspends at several awaits on this
        // MainActor, so without this a second concurrent call would interleave
        // its own quiesce/flip/wipe/rebuild sequence with the first's, and the
        // first call's `defer` would clear `isSwitching` while the second is
        // still mid-flight. Reject the second call outright — the picker UI
        // that drives this is disabled while a switch is running, so this is a
        // defensive backstop, not a path a well-behaved caller should hit.
        //
        // The latch only works because there is exactly ONE coordinator per
        // process: `LibraryLocationSwitcher` builds it once and reuses it for
        // every switch, from either entry point. Constructing a fresh
        // coordinator per call (as `apply` once did) makes this guard
        // unobservable in production.
        //
        // `.switchInProgress` says exactly what happened. It deliberately
        // replaced `.unavailable(root.customURL ?? URL(fileURLWithPath: "/"))`,
        // which told the user their "Library [was] not found at /" — a path
        // nobody chose — and then offered to Locate… it.
        guard !isSwitching else { return .switchInProgress }

        // Set the latch immediately after the guard, BEFORE the validation
        // await below. `validate` genuinely suspends in production (it awaits
        // an actor-isolated lookup on `LibraryContainer`), so the MainActor can
        // schedule a second `switchTo` at that suspension point. If the flag
        // were set only after validation, both calls could read `isSwitching
        // == false` before either one sets it, and the guard above would let
        // both through — reopening the exact interleaved
        // quiesce/flip/wipe/rebuild race this latch exists to prevent. The
        // flag itself is a purely internal re-entrancy latch (no user-visible
        // Library state), so setting it before validation doesn't weaken the
        // "validation precedes every side effect" invariant below.
        isSwitching = true
        defer { isSwitching = false }

        // Validate BEFORE anything is touched: a rejected folder must leave the
        // current Library exactly as it was.
        if case .custom(let url) = root, let error = await dependencies.validate(url) {
            return error
        }

        dependencies.beginSwitch()
        await dependencies.quiesce()

        do {
            try await dependencies.applyRoot(root)
            await dependencies.rebootstrapVault()
            await dependencies.wipeIndex()
            // `.lockedVault` is a SUCCESS: switching back to an encrypted
            // iCloud Library rebuilds nothing precisely because the fresh vault
            // is locked, and the gate below settles on `.locked` so the user
            // can unlock. Only `.failed` — a genuinely unreadable new root
            // paired with a just-wiped index — blocks.
            if case .failed(let url) = try await dependencies.rebuildIndex() {
                throw LibraryRootError.unavailable(url)
            }
        } catch {
            // Past the flip. Deliberately no revert: restoring the old root now
            // would pair it with an index built (or half-built) for another one.
            // Block instead, and let the user choose Locate… or iCloud.
            //
            // Name the path that ACTUALLY failed: the thrown error's own URL
            // when it carries one, else the folder the user picked for this
            // switch. A switch back to iCloud has neither, and reports `nil` —
            // the UI words itself for that rather than being handed a
            // fabricated "/" it would then invite the user to Locate….
            let reported = error as? LibraryRootError
            dependencies.reportUnavailable(reported?.unavailableURL ?? root.customURL)
            return reported ?? .switchFailed
        }

        // Clear the gate BEFORE restarting the store: `restartStore`'s reconcile
        // checks `shouldAutonomousReconcile`, which reads the gate — if it still
        // said `.switchingRoot` the reconcile would bail and the new root's
        // `iCloudStatus`/album state would never refresh.
        await dependencies.endSwitch()
        await dependencies.restartStore()
        return nil
    }
}

extension LibraryRootCoordinator {
    /// Production wiring against the real container, vault provider and store.
    static func live(store: LibraryStore) -> LibraryRootCoordinator {
        let provider = LibraryVaultProvider.shared
        let container = LibraryContainer.shared
        let rootStore = LibraryRootStore.standard

        return LibraryRootCoordinator(dependencies: Dependencies(
            validate: { url in
                // Async so the seam can resolve the app's own iCloud items
                // directory itself rather than trusting a caller to have
                // checked separately — a caller reaching `switchTo(.custom(...))`
                // without that check would otherwise be able to persist a
                // ubiquity path as a "custom" root.
                let iCloudItems = await container.iCloudItemsDirectoryIfAvailable()
                return rootStore.validate(url, iCloudItemsDirectory: iCloudItems)
            },
            beginSwitch: { provider.beginRootSwitch() },
            quiesce: { await store.quiesceForRootSwitch() },
            applyRoot: { root in await container.setRoot(root) },
            rebootstrapVault: { await provider.rebootstrap() },
            wipeIndex: { await store.indexService.wipe() },
            rebuildIndex: {
                // Resolve the directory and the generation in ONE actor-isolated
                // call and pass both through to `rebuild`: resolving them
                // separately reopens the exact race `resolveItemsDirectory()`
                // exists to close (a `setRoot` landing between the two reads
                // would pair the OLD root's directory with the NEW root's
                // generation, so `shouldApplyScan` would wrongly accept a scan
                // of the old root into the new root's index).
                let resolved = try await container.resolveItemsDirectory()
                let outcome = await store.indexService.rebuild(
                    itemsDirectory: resolved.url,
                    startedAtGeneration: resolved.generation
                )
                // `rebuild` is non-throwing and returns `.didNotScan` for a locked
                // vault, an unreadable container, or a generation that moved.
                guard outcome == .didNotScan else { return .scanned }
                // Split those apart. A LOCKED vault is what switching back to an
                // encrypted iCloud Library is SUPPOSED to look like:
                // `rebootstrap()` above built a fresh `LibraryVault` with no
                // cached DEK, so it reads `.locked` the instant `vault.json`
                // exists (only the unlock UI ever calls
                // `unlockWithBiometrics()`), and reconcile's locked guard then
                // correctly declines to scan rather than pruning the index. The
                // switch succeeded; the gate settles on `.locked` and the user
                // unlocks as normal. Reporting it as a failure instead used to
                // strand the user: the index was already wiped, the gate blocked
                // with "Library not found at /", and its only two exits were
                // Locate… and a "Switch Back to iCloud" that reproduced the same
                // failure — with the unlock UI unreachable behind the block.
                if await provider.isVaultLocked() { return .lockedVault }
                // Everything else the guard was added for — an unreadable
                // container leaving a wiped index reported as success — still
                // fails into the blocked state.
                return .failed(resolved.url)
            },
            restartStore: { await store.restartAfterRootSwitch() },
            endSwitch: { await provider.endRootSwitch() },
            reportUnavailable: { provider.reportRootUnavailable($0) }
        ))
    }
}
