# Sort Assistant — Design

**Date:** 2026-06-10
**Status:** Approved

## Goal

Help the user sort a large Library (~7,000 items, ~2,000 already in albums) into
albums using LLM classification of each item's generation prompt. Classification
is text-only: it reads the prompt from the sidecar JSON (always local, even when
media is evicted to iCloud), so the entire library can be processed offline-from-
media, cheaply, via OpenRouter (default model: DeepSeek V4).

Nothing is ever auto-filed. The assistant produces suggestions; the user reviews
and accepts them in a grouped review UI. Accepted memberships are written through
the existing `LibraryAlbumService` path.

## Non-goals (v1)

- No vision/image-based classification (possible later refinement).
- No auto-classification on save. Runs are manual, on demand.
- No persistence of un-reviewed classification results across app launches —
  a run is cheap (<$1 for the full library) and re-runnable.
- No on-device Foundation Models backend (possible later swap).

## Architecture

### Data model changes

**`LibraryAlbumFile`** (container `album-{uuid}.json`, source of truth) gains two
optional fields, decoded with `decodeIfPresent` so existing files remain valid:

- `userDescription: String?` — optional, user-written, edited in album UI.
- `aiProfile: AlbumAIProfile?` — `{ text: String, builtAt: Date, sampleCount: Int }`,
  the LLM-distilled one-paragraph description of what the album contains.
  `sampleCount` records how many member prompts the profile was built from, used
  for staleness detection.

`PersistedAlbum` (disposable index) denormalizes both fields; reconcile rebuilds
them from the album files, same as `name`.

**Rejection memory:** a single `sort-assistant-state.json` file in the container,
mapping itemID → array of rejected album UUIDs (and a flag for "rejected as
new-album suggestion"). Read/written with the same `NSFileCoordinator` pattern
as `LibraryAlbumStore`, on a dedicated serial queue (never the cooperative pool —
grey-spinner rule). It survives index rebuilds, syncs across devices, and never
touches item sidecars, so recording a rejection causes no reconcile churn.

Item sidecars are untouched until the user accepts a suggestion; acceptance goes
through the existing `LibraryAlbumService` membership write path.

### New service: `OpenRouterService` (Services/Networking)

- Structured like `CivitaiService`: thin async HTTP layer.
- API key stored alongside the Civitai key pattern (UserDefaults via a manager),
  entered in Settings. Model identifier is a Settings string, default DeepSeek V4.
- Chat-completions endpoint with JSON-mode responses.
- The LLM call surface is a protocol (`PromptClassifying`) so the pipeline is
  testable with a stub.

### Classification pipeline (`SortAssistantService`)

**Phase 1 — Album profiles** (run when an album has no profile, or is stale:
current membership count ≥ 2 × `sampleCount`, i.e. the album has at least
doubled since the profile was built):

1. For each album: sample ~10 member prompts (spread across the membership, not
   just the newest) + `userDescription` if present.
2. One LLM call per album → profile paragraph → written to the album file.
3. Profiles are user-visible and editable from the album UI.

**Phase 2 — Classify:**

1. Candidate set: items with `albumIDs` empty, minus (item, album) pairs in the
   rejection state. Items with no generation prompt (videos, bare uploads) are
   excluded from API calls but surfaced in review as "Couldn't classify".
2. Batches of ~25 prompts per request, each request carrying all album profiles.
3. Response JSON per item: zero or more `{ albumID, confidence }`, or a proposed
   new album name for items fitting no existing album. Malformed entries are
   dropped with a count reported.
4. A few requests run concurrently; progress is shown; the run is cancellable.
   Completed batches keep their results on failure/cancel (partial review is fine).
5. Results are held in memory for the review step.

### UI flow

- **Entry point:** Sort Assistant button on the Albums browser with an
  "N unsorted" badge computed from the index (`isInAnyAlbum == false`).
- **Sheet flow:**
  1. *Profiles step* — shown only when profiles are missing/stale; displays
     generated profiles for confirmation/editing before first classify.
  2. *Progress step* — batch progress, cancel.
  3. *Grouped review* — one row per existing album with suggestion count, rows
     for each proposed "New album: <name>", an "Unmatched" row (low/no
     confidence), and "Couldn't classify" (no prompt).
- **Group detail:** grid of suggested items (reusing Library grid components),
  sorted by confidence descending, all pre-selected. User deselects misses,
  taps Accept. Long-press opens the existing Manage Albums sheet for an item.
- **Accept semantics:** selected items get membership added via
  `LibraryAlbumService`; for a new-album group the album is created first.
  Deselected items are recorded as rejections in the state file.
- An item suggested for multiple albums appears in each group; accepting
  multiple groups adds multiple memberships (many-to-many already supported).

## Edge cases

- **API/auth failure mid-run:** keep completed batch results, report partial
  completion. Re-running naturally resumes: accepted items are no longer
  unsorted, rejected pairs are filtered.
- **Album renamed/deleted between classify and accept:** membership writes go
  through `LibraryAlbumService`, which validates the album exists; stale
  suggestions for a deleted album are dropped at accept time.
- **Prompt-less items:** never sent to the API; listed under "Couldn't classify".
- **Concurrency/file I/O:** all coordinated file reads/writes on dedicated
  serial queues per the grey-spinner cooperative-pool rule.

## Cost envelope

~5,000 prompts × a few hundred tokens, batched, ≈ 1.5M tokens per full run —
well under $1 at DeepSeek pricing. Re-runs only process still-unsorted items,
so cost decreases monotonically.

## Testing

- `LibraryAlbumFile` back-compat: old JSON without new fields decodes; new
  fields round-trip.
- Rejection state store: round-trip, merge of new rejections, unknown-field
  tolerance.
- Candidate selection: excludes album members, rejected pairs, prompt-less items.
- Batch response parsing: valid JSON, malformed entries dropped + counted,
  unknown albumIDs dropped.
- Pipeline behavior with a stubbed `PromptClassifying`: partial failure keeps
  completed batches; cancellation; profile staleness trigger.
- Accept path: membership written through `LibraryAlbumService`, new-album
  creation ordering, rejections recorded only for deselected items.
