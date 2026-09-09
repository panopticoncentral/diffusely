# Making a Network-Mounted Library Root Usable

**Date:** 2026-09-07
**Status:** Approved design, ready for implementation plan

## Problem

The arbitrary-location feature (`2026-09-07-library-arbitrary-location-design.md`) shipped with a
stated constraint: a custom root is **local storage only**. Pointing it at a Synology SMB share
immediately exposed why.

The reconcile scan reads every item sidecar **serially**, one coordinated read per item. On a local
disk that is microseconds per file and invisible. On a network mount each read is a round trip, and
there are ~8,000 of them. An observed rebuild against a 16,324-file share stayed in its scan phase for
**12+ minutes**, and — worse — it is not a one-time import cost: reconcile performs a **full re-scan**
on launch and after every folder change, so the cost repeats for the life of the Library.

The goal is to make a network-mounted root behave reasonably: a first-time scan in seconds rather than
minutes, and an ordinary launch that costs a directory listing rather than a full re-read.

## Measurements

Measured on the actual share, 8,151 item sidecars among 16,324 files:

| Operation | per file | extrapolated to 8,151 sidecars |
|---|---|---|
| Full directory listing, with prefetch keys | — | **2.24 s** |
| Sequential coordinated read (**what ships today**) | 6.28 ms | **51 s** |
| Sequential plain read (no coordination) | 3.89 ms | 31.7 s |
| 4-way concurrent, plain | 1.10 ms | 9.0 s |
| 8-way concurrent, plain | 0.64 ms | 5.2 s |
| 16-way concurrent, plain | 0.51 ms | 4.2 s |
| 32-way concurrent, plain | 0.47 ms | 3.8 s |
| 8-way concurrent, coordinated | 0.75 ms | 6.1 s |
| 16-way concurrent, coordinated | 0.64 ms | 5.2 s |
| `resourceValues` for the ubiquity keys | 0.01 ms | ~0 (prefetched by the listing) |
| `fileExists` stat | 0.91 ms | 7.4 s |
| Root existence re-check (custom-root cache guard) | 0.002 ms | ~0 |
| **Sequential coordinated read, COLD (actually measured, real scan)** | **69.06 ms** | **562.88 s** |
| **8-way concurrent, coordinated, COLD (actually measured, real scan)** | **489.67 ms/worker (~75.11 ms/file wall)** | **612.24 s** |

**Two caveats, stated up front because an earlier measurement in this investigation was wrong for
exactly this reason:**

1. The app had scanned every one of these files twice immediately before, so the SMB client cache is
   warm and the **absolute** numbers are optimistic. The **scaling curve** is the load-bearing result,
   and it survives the caveat — cold reads are more latency-bound, so concurrency helps more, not less.
2. These numbers predict ~51 s for a scan observed to take 12+ minutes. A debug build, a cold cache and
   repeated full scans plausibly account for a 14x gap, but nothing here proves it. **Task 0 is to
   instrument the real scan** rather than build on a synthetic benchmark.

**Caveat 1 was wrong, and the concurrency prediction it fed was falsified on real hardware.** Task 0's
cold, real-share measurement put the serial read at 69.06 ms/file — 11x the warm-cache benchmark's
6.28 ms/file, not the "more latency-bound, so concurrency helps more" direction predicted above. Task 2
then implemented and measured the 8-way concurrent read cold: 612.24 s wall against 562.88 s serial —
concurrency made it slightly WORSE, not ~8x better, and per-worker cost was 489.67 ms/file (~61 ms/file
of that is real work once the 8-way overlap is divided out — indistinguishable from the 69.06 ms/file
serial baseline). Something below `LibraryFileStore.read` — the file-coordination arbiter, or the
kernel SMB client serializing on one connection despite separate `NSFileCoordinator` instances — was
already serializing the reads regardless of thread count, which the warm-cache benchmark could not see
because a warm client cache has nothing left to serialize on. The concurrency was reverted in the
branch's final fix wave; Part 1's phase split (classify, then read) was kept, since Part 2's per-sidecar
skip needs it regardless of whether the read phase is concurrent.

## What the measurements ruled OUT

Recorded because these were the author's own proposals before measuring, and the data contradicted them:

- **Skipping `NSFileCoordinator` for non-iCloud roots.** Assumed to be a heavy tax. It is ~60% when
  serial but only ~25% once reads run in parallel with a fresh coordinator per operation, and it is not
  a serialization bottleneck. Not worth the correctness argument. **Dropped.**
- **Throttling the custom-root existence re-check.** Assumed to put a network round trip on the
  image-loading path. It measures 0.002 ms — the client caches the directory itself. **Withdrawn; no
  change needed.**

And one item the data ruled IN, which was not in the original plan:

- **The per-item `fileExists` stat** (0.91 ms, 7.4 s total) is invisible today behind a 51 s serial
  read, but becomes the dominant serial cost the moment reads are parallelized.

## Decisions

| Question | Decision |
|---|---|
| Instrument before optimizing | **Yes** — a 14x unexplained gap is not a foundation to build on |
| Concurrency mechanism | **GCD** (`OperationQueue` / `concurrentPerform`), never Swift concurrency |
| Concurrency width | Bounded, default 8, single named constant |
| Incremental fingerprint | Sidecar **modification date + byte size**, from the listing |
| Fingerprint storage | New optional fields on `PersistedLibraryItem` |
| Applies to encrypted roots too | **Yes** — via a stored sidecar filename, not a filename-derived id |
| Skip coordination for custom roots | **No** (measured: not worth it) |
| Change the root existence re-check | **No** (measured: free) |

## Architecture

### Part 0 — Instrument the real scan

Add opt-in timing to `scanContainer`: count of sidecars read, total and mean read time, listing time,
stat count and time, and the number of scan passes per reconcile (the epoch-retry loop can run up to
three). Emit once per scan through the existing `print` diagnostics the Library already uses.

This is the task's deliverable — a real measurement of a real scan on the share, at both a debug and a
release build — and it gates the rest. If the gap turns out to be the debug build, the remaining parts
are still worth doing but their expected payoff changes, and the plan should say so rather than
quietly assuming a 10x.

### Part 1 — Concurrent sidecar reads (attempted, then reverted — see below)

`scanContainer` currently walks the listing and, per item, reads and decodes the sidecar. Split it:

1. Build the work list from the listing (no I/O beyond the listing itself — already the case).
2. Read and decode sidecars **concurrently**, bounded width, collecting `(metadata, status)` results.
3. Assemble `ScanResult` and return it, unchanged in shape.

**The concurrency must be GCD, not Swift concurrency.** `scanQueue` exists precisely to keep blocking
`Data(contentsOf:)` off the cooperative pool; this repo has a documented history of pool starvation
presenting as a grey spinner. Using `async let` or a `TaskGroup` here would reintroduce it at 8x the
width. `scanQueue` remains the serial *driver* — its comment ("serial, so overlapping reconciles can
never block more than one thread") stays true at the reconcile level; the bounded inner pool is an
implementation detail of one scan, and its width is the cap on threads that scan can occupy.

Each concurrent operation gets its **own** `NSFileCoordinator`. Sharing one across threads is what
would serialize them, and is how a naive parallelization would measure no faster.

Results must be **order-independent**: collect into a dictionary keyed by item id, or into a
pre-sized array by index, and assemble deterministically afterwards. `ScanResult.items` ordering must
not become dependent on completion order, or reconcile's behaviour becomes nondeterministic.

**Outcome, recorded here rather than only in the task ledger because this section's premise turned out
to be wrong: the concurrency was implemented exactly as designed above, measured cold against the real
share, and reverted.** The `Measurements` section's "8-way concurrent, coordinated" row (0.75 ms/file,
predicting ~6.1 s) was a warm-cache number; the cold, real-share equivalent measured 489.67 ms/file
summed per worker (612.24 s wall) against a 69.06 ms/file, 562.88 s wall serial baseline — concurrency
made the scan slightly *worse*, not ~8x faster, because the warm-cache benchmark was 11x optimistic on
reads and something below the per-operation `NSFileCoordinator` (the file-coordination arbiter, or the
kernel SMB client on one connection) was already serializing the reads regardless of thread count. The
three points above (GCD not Swift concurrency, one coordinator per operation, order-independent
results) remain correct engineering for *if* concurrency is ever revisited on hardware where it
actually helps — they were not the mistake. The mistake was trusting a warm-cache scaling curve to
predict cold-read behavior on this specific network filesystem. The classify/read phase split this Part
also describes was kept regardless, since Part 2's per-sidecar skip needs it independent of whether the
read phase is serial or concurrent.

### Part 2 — Incremental reconcile

The structural fix. Today every reconcile re-reads every sidecar. Instead, skip any sidecar whose
fingerprint is unchanged since the index last ingested it.

**Fingerprint:** the sidecar's `contentModificationDate` and `fileSize`, both obtainable from the
directory listing by adding them to the existing prefetch keys — so the fingerprint for every file
costs nothing beyond the 2.24 s listing already being paid.

**Storage:** three new fields on `PersistedLibraryItem`:

```swift
var sidecarFileName: String = ""
var sidecarModifiedAt: Date?
var sidecarByteSize: Int = 0
```

All additive with defaults, matching the established pattern (`needsDateBackfill`,
`albumIDsJoined`). No migration plan is needed: `DiffuselyApp` already implements **"Rebuild, don't
migrate"** — a `ModelContainer` that fails to open destroys the store and recreates it, and this index
is disposable by design. Existing rows load with empty fingerprints, which simply means "unknown, so
read it" — the first reconcile after upgrade is a full scan that populates them.

**Why store the filename.** Encrypted sidecars have opaque HMAC names carrying no item id, so the id
cannot be recovered from a listing without reading the file. Storing the name each row was built from
lets the listing be mapped to ids for *both* modes, so incremental reconcile benefits an encrypted
iCloud Library too, not just a plaintext custom root.

**THE CORRECTNESS RULE.** `seenIDs` drives pruning: any indexed id absent from it is deleted from the
index. A skipped item is still *present* — so **every skipped sidecar's id MUST be inserted into
`seenIDs`**. Getting this wrong prunes the entire unchanged Library on the first incremental
reconcile, which is the exact catastrophe the generation counter and the eviction-sweep guards exist
to prevent. This deserves its own test, asserting row survival and not merely a return value.

A full, non-incremental scan must remain available and must be what `rebuild(itemsDirectory:)` runs —
Settings' "Rebuild Index" means "distrust the index", so it must not consult the fingerprints it is
meant to be rebuilding.

### Part 3 — Remove the per-item `fileExists`

`downloadStatus(for:fileManager:)` falls back to a `fileExists` stat per item (0.91 ms; 7.4 s total).
The directory listing already enumerated every file, and `scanContainer` already builds `urlsByName`
from it. Derive media presence from that map instead of stat'ing, keeping the existing ubiquity-status
logic for iCloud roots where it is genuinely needed.

This is only worth doing after Part 1; before it, it is 13% of a 51-second problem.

## Testing

- **Part 0:** none beyond the instrumentation reporting plausible values; its output is the deliverable.
- **Part 1:** a scan over a seeded directory must produce a `ScanResult` **identical** to the serial
  implementation's — same items, same statuses, same `seenIDs`, same ordering. The cheapest honest form
  is a fixture directory scanned both ways with the results compared. Plus a test that a sidecar which
  fails to read still preserves its row (the existing "torn write" rule) under concurrency.
- **Part 2:** the prune-safety test above is mandatory — seed an index, run an incremental reconcile
  where nothing changed, assert every row **survives** and no sidecar was read. Then: a changed
  fingerprint causes a re-read; a new file is ingested; a deleted file is pruned; `rebuild` ignores
  fingerprints entirely.
- **Part 3:** media presence resolves identically with and without the listing shortcut, including for
  an item whose media is absent.
- The suite must stay green on both harnesses, and iOS must keep building.

## Risks

- **The 14x gap is unexplained.** If Part 0 shows the real bottleneck is elsewhere — decode cost in a
  debug build, the epoch-retry loop running three passes, contention with the folder watcher — then
  Parts 1–3 are still correct but may not deliver the expected improvement. Part 0 exists to find that
  out before the effort is spent.
- **Incremental reconcile is the highest-risk change in this codebase's history of index pruning.**
  Every prior incident in this area came from treating "not seen" as "deleted". Part 2 deliberately
  makes more things "not read" — the mitigation is that "not read" must never reach the pruning path.
- **mtime granularity and clock skew on a network filesystem.** SMB modification times can be coarse or
  skewed relative to the client. Pairing mtime with byte size mitigates it; a same-size edit within the
  timestamp's resolution would be missed until the next full rebuild. Acceptable for an index that has
  a manual rebuild and is disposable by construction.
- Widening concurrency raises peak memory during a scan (N sidecars decoded at once). At width 8 and
  sidecar sizes measured in kilobytes this is negligible, but the width constant should be one place.

## Out of scope

- Making network roots a *supported* configuration in the product sense. This work makes one usable;
  the spec's local-only constraint stands until someone decides otherwise deliberately.
- Any change to file coordination, or to the custom-root existence re-check. Both measured as
  non-problems above.
- Incremental *album* scanning. Albums number in the dozens, not thousands.
- Parallelizing anything other than the scan's reads — the apply step stays serial on the model actor.
