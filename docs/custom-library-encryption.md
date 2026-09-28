# Encryption in custom library folders

Custom library folders support the same password, recovery-key, and biometric unlock flow as the iCloud library. Folder selection remains available on macOS; this change does not add the iOS folder picker.

## Storage

Every library folder contains the library files plus `vault.json` and `vault.backup.json`. Encrypted items keep the existing opaque `.m`, `.b`, and `.x` format. In iCloud, this self-contained folder is `Documents/Items`; for custom storage, it is the selected folder. An interrupted disable also keeps its `vault.disabling` marker in that folder.

To copy a library from custom storage into empty iCloud storage, copy the entire contents of the selected folder into Diffusely's `Documents/Items`. To copy it back, copy the entire contents of `Items` into an empty custom folder. Include both vault files; no rearrangement or re-encryption is needed, and the same password or recovery key unlocks the copy. Finish any conversion and close Diffusely on all devices before copying; reopen after the copy completes and let iCloud sync to other devices. The index can be rebuilt from the copied metadata.

A custom folder containing ciphertext without a vault file is rejected. A backup vault alone can be used to unlock. This layout assumes there are no existing iCloud encrypted libraries using vault files in the parent `Documents` folder; that earlier layout is not migrated automatically.

Custom storage must expose readable files (for example, a local disk or mounted SMB share). Encryption does not add support for downloading third-party provider placeholders. Custom originals are not evicted by the iCloud cache controls. CDN previews work after unlocking, just as in the iCloud library.

## Conversion and recovery

Enabling encryption reads and rewrites all originals, sidecars, and supported auxiliary records. Each conversion verifies the destination before deleting its source. Failed directory listings are errors, not empty libraries; conversion writes never create a missing root. Disabling persists its direction before changing files and retains the vault until a successful listing confirms no encrypted files remain.

Plaintext change journals are removed after successful encryption. Encrypted custom folders use folder watching and periodic reconciliation rather than plaintext journals. A leftover journal keeps setup incomplete so cleanup can resume.

Location switching is blocked during encryption operations. A completed switch discards the old coordinator and locks the old vault. Update every client that accesses an encrypted custom library; perform conversions with other clients closed. Testing simulates disconnects by moving temporary folders; real SMB failure behavior still requires device/network validation.

## Key compatibility

Biometric keys are stored separately per vault, using an identity derived from its recovery wrapping. Moving a library or changing its password does not change this identity. A key-verification field prevents a mismatched cached key from unlocking the library.

Existing vault files remain readable with their password or recovery key. The first such unlock adds the optional verification field and establishes the scoped biometric cache. The previous global Keychain entry is not used to unlock arbitrary libraries. This requires one password/recovery unlock per device before biometrics can be used again.
