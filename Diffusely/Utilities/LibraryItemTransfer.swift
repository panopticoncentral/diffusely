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

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .item) { transfer in
            let dir = try await LibraryContainer.shared.itemsDirectory()
            return SentTransferredFile(dir.appendingPathComponent(transfer.mediaFileName))
        }
        CodableRepresentation(contentType: .diffuselyLibraryItem)
    }
}
