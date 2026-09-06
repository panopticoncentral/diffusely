import SwiftUI
import UniformTypeIdentifiers

/// Minimal `FileDocument` so `.fileExporter` can write arbitrary bytes under a
/// caller-chosen type. Read support exists only to satisfy the protocol.
struct DataDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    static var writableContentTypes: [UTType] { [.json, .png, .jpeg, .webP, .data] }

    let data: Data
    let contentType: UTType

    init(data: Data, contentType: UTType) {
        self.data = data
        self.contentType = contentType
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        contentType = .data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
