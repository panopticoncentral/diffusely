# Library At-Rest Encryption — Design

**Date:** 2026-07-30
**Status:** Approved, ready for implementation planning

## Summary

Add optional, password-based **at-rest encryption** for the personal Library. When
enabled, every library file in the iCloud container — media (`.jpeg`/`.mp4`), sidecar
JSON, album files, and sort-assistant state — is encrypted with AES-256-GCM under a key
that only the user's password (or a recovery key) can unlock. The raw files that sync
to iCloud and to the user's other devices reveal nothing without that secret: not the
pixels, not the metadata, and not even *which* Civitai images were saved.

Day to day, the Library tab is gated behind Face ID / Touch ID; the password is typed
only at first setup, on a new device, or when biometrics fail. The rest of the app
(browsing Civitai feeds) is unaffected and never locked.

## Motivation

The Library lives in the iCloud Drive ubiquity container
(`iCloud.AchatesSoftware.Diffusely`, `Documents/Items`), so it is visible on every
device signed into the same iCloud account and, in principle, to anyone who can read
those synced files. The user wants the collection protected at rest against that
exposure — another Mac on the same account, an iCloud compromise, or forensic access —
not merely hidden behind a UI gate.

A wrinkle specific to this app shapes the scope: the saved images are **public Civitai
images**, and each sidecar stores `originalCDNURL`. Encrypting only the pixels would be
pointless — an attacker could read the URL from a plaintext sidecar and re-download the
image from Civitai's public CDN. The genuinely private asset is the **collection
itself** (which images, which albums, the generation prompts), which lives in the
sidecars. Therefore media *and* sidecars must both be encrypted, or the feature
protects nothing.

## Threat model & decisions

- **Protect against:** anyone with read access to the raw synced files (another device
  on the same iCloud account, iCloud account compromise, forensic disk access).
- **Encrypt at rest**, not merely a UI lock. (Decision.)
- **Recovery key** as the safety net for a forgotten password — a second, independent
  way to unlock. (Decision. Losing both password and recovery key = data unrecoverable
  by design.)
- **Unlock UX:** Face ID / Touch ID each time the Library is opened, key cached in the
  biometric-protected Keychain; password only on setup / new device / biometric
  failure; auto-lock after the app is backgrounded past a threshold. (Decision.)
- **Video:** decrypt-to-temp for playback and poster frames (not an on-the-fly
  `AVAssetResourceLoader`). Accepts brief, device-local, Data-Protected plaintext that
  never syncs. (Decision; the resource-loader approach can be added later behind the
  same interface.)

## Goals

- Optional, user-enabled encryption of all durable Library files at rest, keyed by a
  user password with standard, OS-provided algorithms only (AES-GCM, PBKDF2, HKDF).
- A recovery key that can unlock independently of the password.
- Biometric unlock with idle auto-lock; the lock gates only the Library tab.
- A one-time, resumable, loss-safe migration of the existing library (~6,500 items).
- Reversible: the user can turn encryption back off and restore plaintext.
- No change to the iCloud sync, on-demand download, or LRU-eviction model.

## Non-Goals (v1)

- On-the-fly (`AVAssetResourceLoader`) streaming decryption of video. Decrypt-to-temp
  is v1.
- Protecting the Library while *unlocked* against a user who is handed the unlocked
  device (that is the UI-gate concern, partially covered by auto-lock, not the at-rest
  goal).
- Hiding library membership from Civitai / network observers during normal *unlocked*
  browsing beyond what encryption already implies (see §2 note on the CDN shortcut).
- Encrypting anything outside the Library (feed cache, following store, collections).
- A third-party Argon2 dependency (PBKDF2 is v1; Argon2id is a documented option).

## Architectural constraints

- **Sidecar-authoritative invariant (preserved):** the sidecar in the container is the
  source of truth; the SwiftData index (`PersistedLibraryItem`) is disposable and
  rebuilt from sidecars. Encryption inserts at the read/write seam; the invariant is
  untouched.
- **Cooperative-pool discipline (preserved):** all blocking file-coordination, ImageIO,
  and now crypto/migration I/O must stay off the Swift concurrency cooperative pool —
  run on a dedicated `DispatchQueue`, never a `Task.detached` storm. (The recurring
  grey-spinner / cooperative-pool-starvation regression.)
- **All devices must run the encryption-capable app version** before enabling. An older
  build would see opaque files with the plaintext gone — a broken library. Precondition
  for enabling, not a runtime concern.

---

## 1. Crypto core & key hierarchy

**Primitives**

- **File encryption:** AES-256-GCM (`CryptoKit.AES.GCM`). Authenticated: corruption or
  tampering is detected on read rather than silently mis-decoded.
- **Password KDF:** PBKDF2-HMAC-SHA256 (`CommonCrypto` `CCKeyDerivationPBKDF`),
  iteration count calibrated to ~0.3–0.5 s on target devices (~600k). Argon2id is the
  stronger alternative and slots into the same seam if a third-party dependency is
  later accepted.

**Key hierarchy (envelope encryption)**

```
password ──PBKDF2(salt_pw)──▶ KEK_pw ─┐
                                      ├─▶ unwrap ─▶ DEK (random 256-bit)
recoveryKey ─PBKDF2(salt_rec)▶ KEK_rec┘                 │
                                        ┌────────────────┴───────────────┐
                              HKDF(info:"content")            HKDF(info:"filename")
                                   contentKey                     fileKey
```

- The **DEK** is a random 256-bit key generated once at setup; it never leaves the
  device in plaintext.
- Two independently derived KEKs each wrap the DEK with AES-GCM, so either the password
  *or* the recovery key can unwrap it. A wrong secret simply fails the GCM auth tag —
  that *is* the "wrong password" signal; no separate verifier is stored.
- From the DEK, HKDF derives `contentKey` (encrypts file bytes) and `fileKey` (computes
  opaque filenames). Each file is encrypted under a further per-file subkey
  `HKDF(contentKey, salt: fileToken)`, so no key is ever reused across files.

**`vault.json`** — lives in the container, syncs across devices, contains zero
plaintext:

```
{ version, kdf: { algo, iterations },
  salt_pw,  wrapped_DEK_pw:  { nonce, ciphertext+tag },
  salt_rec, wrapped_DEK_rec: { nonce, ciphertext+tag } }
```

Its presence is also the "this library is encrypted" flag. A redundant
`vault.backup.json` is written alongside it — this is the one file that cannot be
regenerated, so losing it would strand every encrypted file.

**Recovery key:** 256-bit random, shown once at setup as grouped, transcribable text
(BIP39-style words preferred). Wraps the DEK exactly as the password does.

**Unlock session — `LibraryVault` actor** (single source of truth):

- States: `notConfigured` / `locked` / `unlocked(DEK in memory)`.
- First unlock derives the DEK, then caches it in the Keychain under
  `.biometryCurrentSet` + `.whenUnlockedThisDeviceOnly`. Later launches retrieve it via
  Face ID; password/recovery is the fallback and the new-device bootstrap.
- **Auto-lock:** zeroize the in-memory DEK once the app has been backgrounded past a
  threshold, and on an explicit Lock action. The biometric Keychain copy persists, so
  re-entry is just Face ID.
- The Keychain cache and `LAContext` biometric prompt sit behind protocols so tests can
  inject an in-memory cache; the OS-specific pieces stay at the edges.

## 2. On-disk format, opaque filenames & code seams

**File envelope** — every encrypted file:

```
[ magic "DFEB" | version:1 | AES-GCM sealed box (nonce ‖ ciphertext ‖ tag) ]
```

**Opaque filenames.** The current names `<civitaiID>.json` / `<civitaiID>.<ext>` leak
the collection: the Civitai ID is a *public* identifier, so a directory listing alone
reveals what was saved, without decrypting anything. Names must therefore also stop
leaking:

```
token       = base32( HMAC-SHA256(fileKey, "<role>:<itemID>") )    // role ∈ {meta, media}
on-disk name = <token>.m   (sidecar)   |   <token>.b   (media blob)
```

- Deterministic ⇒ every "find this item's file" call site keeps working by *computing*
  the name from the ID, instead of formatting `"<id>.json"`. No mapping table.
- The `.m` / `.b` suffix leaks only the coarse metadata-vs-blob category (harmless) and
  lets the index rebuild know which files are sidecars to decrypt.
- Index rebuild enumerates `*.m`, decrypts each, and reads `itemID` from *inside* the
  sidecar; the media file is then located by computing its `media` token. `mediaType`
  (already a field) remains the source of truth for image-vs-video, so the old
  `mediaFileName`/extension stops carrying meaning.

**The seam — one `LibraryFileStore`.** A new store owns all container I/O and consults
`LibraryVault`:

- Unlocked & encryption on → encrypt on write, decrypt on read, opaque names.
- `notConfigured` → passthrough to today's plaintext `<id>.json` / `<id>.<ext>`
  behavior, so the existing path and its tests keep working unchanged.

Existing call sites route through it:

| Seam | File | Change |
|---|---|---|
| `LibraryFileWriter` commit / read / rewrite | `LibrarySaveService.swift` | Encrypt sidecar + media on write; decrypt on read; opaque names. The JSON-last "fully saved" commit marker is preserved (encrypted sidecar written last). |
| Byte cascade `loadBytes` | `LibraryImageRequest.swift` | When encrypted, **skip the public-CDN thumbnail shortcut** and decrypt the local file instead — otherwise the grid would issue per-item CDN requests that network-leak exactly which images were saved. Downsample decrypted `Data` in memory; no plaintext to disk. |
| Video poster / player | `LibraryImageRequest.extractPosterFrame`, `LibraryVideoPlayer` | Decrypt-to-temp: write plaintext into an app-private `.completeFileProtection` temp dir **outside** the container, hand that URL to `AVAssetImageGenerator` / `AVPlayer`, delete on teardown, sweep leftovers on launch. |
| Index rebuild / ingest | `LibraryIndexService` | Enumerate `*.m`, decrypt to metadata; access/eviction bookkeeping unchanged. |
| Date backfill rewrite | `LibraryDateBackfillService` | Decrypt → mutate → re-encrypt sidecar. |
| Path helpers | `LibraryContainer.metadataURL/mediaURL(forItemID:)` | Compute opaque names when encrypted. |
| Albums + sort-assistant state | `LibraryAlbumService`, `SortAssistantState` | Same wrapper; album files and `sort-assistant-state.json` encrypted too. |

**Unchanged:** `LibraryFileMaterializer` — iCloud download-on-demand and eviction
operate on opaque ciphertext exactly as before; it does not care what the bytes are.

> **Note (out of scope):** even when unlocked, decrypting locally (rather than using the
> CDN shortcut) means normal browsing no longer re-fetches thumbnails from Civitai for
> saved items, which is a privacy improvement, not a regression.

## 3. Enable / disable, migration & the second device

**Enable (Settings → "Encrypt Library"):**

1. User sets a password (confirm + strength hint). Generate DEK, both salts, recovery
   key.
2. Wrap the DEK under both KEKs; write `vault.json` + `vault.backup.json`.
3. **Show the recovery key once**, gated behind an explicit "I've saved this" (copy
   button; ideally a quick re-enter of a couple of words so it cannot be dismissed
   blindly). Only moment it is ever shown.
4. Run the migration (below). Cache the DEK in the Keychain behind biometrics.

**Migration — one-time, resumable, idempotent, loss-safe.** Per item, in this order so
a crash mid-item is always recoverable:

1. Skip if the encrypted `.m` / `.b` already exist (already done).
2. **Materialize the plaintext locally** if iCloud-evicted — the real bytes are needed
   to re-encrypt.
3. Read plaintext sidecar + media → write encrypted `<token>.m` and `<token>.b`
   (atomic + `NSFileCoordinator`) → **verify the ciphertext round-trips** (decrypts, SHA
   matches) → *only then* delete the plaintext `<id>.json` / `<id>.<ext>`.

Progress derives largely from directory state (plaintext present = pending; `.m`
present = done), backed by a small `migration-state.json` for totals/status. Runs on
the dedicated I/O queue with **bounded concurrency**, survives backgrounding/relaunch,
and rebuilds the disposable index at the end. The Library stays usable throughout: the
store checks the encrypted name first and falls back to plaintext, so items flip over
transparently.

Two costs are inherent and must be surfaced in the enable UI:

- **Every evicted item is pulled local once** during migration — for ~6,500 items, a
  substantial one-time iCloud download. Unavoidable: the plaintext must be read to be
  replaced.
- **Deleting each plaintext file propagates through iCloud**, which is what removes the
  unencrypted copy from all devices.

**Second device.** Only the enabling device runs the migration loop — others must not
race it. `vault.json` and `migration-state.json` sync over; when device B opens the
Library and sees a configured vault, it prompts once for password or recovery key,
derives the DEK, and caches it in *its own* biometric Keychain. It never re-migrates; it
consumes encrypted files as they arrive and tolerates a mixed plaintext/encrypted state
mid-sync.

**Disable / decrypt** (mirror image, requires an unlocked vault): decrypt each item back
to plaintext names, remove the opaque files, delete `vault.json` + `vault.backup.json` +
the Keychain DEK, rebuild the index — same resumable, verify-before-delete safety.

**Password change:** re-derive `KEK_pw` with a fresh salt, re-wrap the DEK, rewrite
`vault.json`'s `wrapped_DEK_pw`. No media file is touched.

## 4. Error handling & edge cases

| Case | Behavior |
|---|---|
| **Wrong password / recovery key** | GCM unwrap of the DEK fails its auth tag → clean `.wrongCredential`, no data risk. PBKDF2 cost already throttles guessing; add a small escalating delay after repeated failures. **No lockout, no wipe.** |
| **Tampered / corrupt file** (GCM auth fails on read) | That one item shows "unavailable" — never crashes the grid. Distinguished from "iCloud not-yet-downloaded" (materialize + retry). For media, offer re-download from `originalCDNURL`; `contentSHA256` (over plaintext) stays a secondary integrity signal. |
| **Interrupted migration** | Resumes from directory state on next launch; verify-before-delete guarantees no loss (worst case: transient double storage). |
| **iCloud conflict / half-synced file** | Reads as not-ready/unavailable, retried when sync settles. Write-once media rarely conflicts; sidecar rewrites (backfill, album edits) are last-writer-wins across devices — accepted. |
| **Biometric change / Keychain invalidation** | `.biometryCurrentSet` invalidates the cached DEK → fall back to password, then re-cache. Not data loss. |
| **New device / reinstall** | Biometric Keychain is device-local, so first unlock is always password/recovery. `vault.json` lives in the synced container, so it survives reinstall and enables post-reinstall unlock. |
| **Lost password AND recovery key** | Unrecoverable by design — stated bluntly in the enable UI. |
| **`vault.json` lost / corrupt** | Recover from `vault.backup.json`. |
| **Save / index while locked** | With encryption on, all Library writes need the DEK. "Save to Library" while locked triggers the unlock flow first; feed browsing (unencrypted) is unaffected. |
| **Disk full during migration/write** | Atomic write fails → the item stays plaintext (not yet deleted) → safe, retried. |

## 5. Testing

Mirror the existing `DiffuselyTests/Library*Tests` style — services are
directory-injected and unit-testable against a temp directory, with no iCloud or
Keychain dependency:

- **Crypto round-trip:** encrypt → decrypt returns the original; wrong key rejected; a
  flipped byte throws an auth failure.
- **Envelope:** wrap/unwrap the DEK under both password and recovery key; wrong
  credential rejected; password change re-wraps yet the DEK is unchanged (existing media
  still decrypts).
- **Filenames:** token deterministic per `(id, role)`; distinct ids/roles → distinct
  tokens.
- **Store passthrough:** `notConfigured` mode reads/writes today's plaintext layout
  unchanged (guards against regressing existing behavior).
- **Migration:** forward pass encrypts everything and removes plaintext; decrypt matches
  original; **idempotent** (run twice = no-op); **resumable** (kill after N items →
  resume completes); verify-before-delete (an injected bad write keeps the plaintext);
  reverse/disable restores plaintext.
- **Index rebuild** from encrypted sidecars yields the same items as from plaintext.
- **Tamper isolation:** one corrupt item → unavailable; the rest of the library fine.

The `LibraryVault` key-cache (Keychain) and biometric prompt (`LAContext`) sit behind
protocols so tests inject an in-memory cache.

## Note — export compliance

Not applicable while the app is personal / non-distributed: US EAR export rules and
Apple's `ITSAppUsesNonExemptEncryption` declaration are triggered by *distribution*
(App Store, TestFlight, or sharing a build), not by using encryption. **If this is ever
distributed, revisit the US EAR export declaration** — the algorithms here are standard,
so it falls in the mass-market self-classification lane (`ITSAppUsesNonExemptEncryption
= true` + an annual year-end self-classification report; France/ANSSI declaration if
distributed there).

## Open questions

- **PBKDF2 vs Argon2id:** v1 ships PBKDF2 (no new dependency). Revisit if an Argon2
  SPM dependency becomes acceptable.
- **Recovery-key encoding:** BIP39-style word list vs grouped Base32 — a UX/transcription
  detail to settle during implementation.
