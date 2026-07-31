import Foundation
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// Private drag payload identifying a saved Library item, so an in-app album
    /// tile can accept a drop without touching the file bytes.
    static let diffuselyLibraryItem = UTType(exportedAs: "com.achatessoftware.diffusely.library-item")
}

/// Draggable representation of a saved Library item, with two faces:
///   • a **file**, so dragging a grid cell out to Finder / Photos / Messages
///     copies the original media (the primary macOS use);
///   • an **id-only codable payload**, so an in-app album-tile `.dropDestination`
///     can add the item to that album without materializing anything.
///
/// The file is exported as the generic `.item` type: the library mixes images
/// and videos, `TransferRepresentation` is static (can't branch per instance),
/// and `SentTransferredFile` preserves the real filename/extension, so Finder
/// and other file consumers still treat the copy correctly.
struct LibraryItemTransfer: Codable, Transferable {
    let itemID: Int
    let mediaFileName: String

    /// Thrown when the drop can't produce a file: the vault is locked (T17
    /// gates the whole Library while locked, so this shouldn't normally
    /// happen), or the encrypted media couldn't be read/decrypted.
    private enum TransferError: Error { case unavailable }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .item) { transfer in
            let (state, fileStore) = await LibraryVaultProvider.shared.reconcileContext()
            // Defensive: never fall through to `fileStore`'s passthrough
            // behavior while locked (a locked snapshot's store is a
            // plaintext passthrough by design) — that would build a legacy
            // plaintext name over what's actually an encrypted container.
            guard state != .locked else { throw TransferError.unavailable }

            let ext = (transfer.mediaFileName as NSString).pathExtension
            if fileStore.isEncrypted {
                // Drag-out hands the URL to the system, which copies the file
                // itself with no completion signal back to us — so unlike
                // Quick Look, this temp file is deliberately NOT removed
                // here. It's reclaimed by `LibraryTempMedia.sweep()` instead.
                guard let tempURL = await LibraryTempMedia.materialize(
                    store: fileStore, itemID: transfer.itemID, plaintextExtension: ext
                ) else { throw TransferError.unavailable }
                return SentTransferredFile(tempURL)
            }
            return SentTransferredFile(fileStore.mediaURL(itemID: transfer.itemID, plaintextExtension: ext))
        }
        CodableRepresentation(contentType: .diffuselyLibraryItem)
    }
}
