# Incremental library indexing

Full scans enumerate the flat library in batches of at most 256 directory
entries. Each batch publishes index rows and refreshes the library UI. Only a
completed walk may prune missing rows. Cancellation, enumeration errors, root
changes, or a changed journal defer that final prune. Direct index mutations
invalidate the in-flight scan's epoch and trigger a bounded retry.

Settings → Rebuild Index displays progress and offers Stop. Completed batches
are saved in SwiftData. A local checkpoint under Application Support records
only fingerprints committed by that rebuild. An ordinary launch reconcile also
resumes a pending rebuild. Resume starts directory enumeration again, checks the
current fingerprints, and skips reading unchanged metadata from committed
batches. It does not persist or trust directory offsets. Successful completion
removes the checkpoint; a later explicit rebuild starts fresh. A batch whose
save needs per-item recovery is not checkpointed as wholly successful.

Custom plaintext roots gain a hidden `.diffusely-changes` directory. Each
installation owns an atomic JSON journal with up to 512 completed transactions.
Writes publish an intent before changing a library file, then publish the
changed filenames. Metadata, media, album, and deletion operations use this
path; existing adapters recognize an initialized journal directory too.
Encrypted roots do not write plaintext journals.

After a stable complete scan, normal refreshes can read the small journals and
update only affected rows. Missing or corrupt logs, pending transactions,
sequence gaps, reset journals, or a large delta fall back to a full scan. A
reset journal has a new incarnation so old cursors cannot silently skip history.
Journal cursors are session-local; relaunch establishes a new full baseline.

The custom-root watcher also checks once a minute while idle. After five
minutes since the last successful full audit, the next check performs another
full scan to discover changes made by external tools or older app versions.
These edits are therefore eventually detected, not guaranteed to appear
immediately. Rebuild Index remains the explicit full verification operation.

Blocking enumeration, file reads, journal reads, and checkpoint writes stay on
the scan queue. Resumption still pays directory-enumeration cost, and Stop takes
effect after the current blocking filesystem operation/batch returns.
