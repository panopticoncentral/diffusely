import Foundation

/// Each installation owns one bounded log. Writers on different machines never
/// replace the same file. A pending transaction, lost history, or unreadable log
/// forces an authoritative scan rather than silently skipping changes.
struct LibraryChangeJournal {
    static let directoryName = ".diffusely-changes"
    static let historyLimit = 512
    let directory: URL
    let writerID: String?

    private static let installationID: String = {
        let key = "libraryJournalInstallationID"
        if let value = UserDefaults.standard.string(forKey: key), UUID(uuidString: value) != nil { return value }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }()

    init(root: URL, writerID: String? = nil) {
        directory = root.appendingPathComponent(Self.directoryName, isDirectory: true)
        self.writerID = writerID
    }

    struct Entry: Codable, Equatable {
        var sequence: Int
        var names: [String]
    }
    struct Document: Codable, Equatable {
        var version = 1
        var incarnation = UUID()
        var revision = UUID()
        var sequence = 0
        var pending: [String: [String]] = [:]
        var entries: [Entry] = []
    }
    struct Snapshot: Equatable {
        var writers: [String: Document]

        var isClean: Bool { writers.values.allSatisfy { $0.pending.isEmpty } }

        /// nil means a gap or invalid history, NOT an empty change set.
        func changes(since previous: Snapshot) -> Set<String>? {
            guard isClean, previous.isClean,
                  Set(previous.writers.keys).isSubset(of: Set(writers.keys)) else { return nil }
            var names = Set<String>()
            for (writer, document) in writers {
                if let prior = previous.writers[writer], prior.incarnation != document.incarnation { return nil }
                let old = previous.writers[writer]?.sequence ?? 0
                guard document.sequence >= old else { return nil }
                if document.sequence == old {
                    guard previous.writers[writer] == nil || previous.writers[writer] == document else { return nil }
                    continue
                }
                let entries = document.entries.filter { $0.sequence > old }
                guard entries.first?.sequence == old + 1,
                      entries.last?.sequence == document.sequence,
                      entries.count == document.sequence - old,
                      entries.enumerated().allSatisfy({ $0.element.sequence == old + $0.offset + 1 }) else { return nil }
                for entry in entries { names.formUnion(entry.names) }
            }
            return names
        }
    }

    enum JournalError: Error { case invalidHistory }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    func snapshot() throws -> Snapshot {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var writers: [String: Document] = [:]
        for url in urls where url.pathExtension == "json" {
            guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { throw JournalError.invalidHistory }
            let value = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
            guard value.version == 1, value.sequence >= 0,
                  value.entries.count <= Self.historyLimit,
                  value.entries.allSatisfy({ $0.names.allSatisfy(Self.validName) }),
                  value.pending.values.allSatisfy({ $0.allSatisfy(Self.validName) }) else { throw JournalError.invalidHistory }
            writers[url.lastPathComponent] = value
        }
        return Snapshot(writers: writers)
    }

    /// The intent is durable BEFORE changing a library file. A crash or failure
    /// to publish completion leaves that intent visible to every reader.
    func withMutation<T>(names: [String], _ operation: () throws -> T) throws -> T {
        guard names.allSatisfy(Self.validName), UUID(uuidString: writerID ?? Self.installationID) != nil else { throw JournalError.invalidHistory }
        let transaction = UUID().uuidString
        try update { $0.pending[transaction] = names }
        let value: T
        do { value = try operation() }
        catch {
            // The operation may have partially succeeded. Publish the names so
            // readers inspect the actual files, even when the caller sees error.
            try? finish(transaction: transaction, names: names)
            throw error
        }
        // If this fails, retain the pending intent and let full scans recover.
        try? finish(transaction: transaction, names: names)
        return value
    }

    private func finish(transaction: String, names: [String]) throws {
        try update {
            $0.pending.removeValue(forKey: transaction)
            $0.sequence += 1
            $0.entries.append(Entry(sequence: $0.sequence, names: names))
            $0.entries = Array($0.entries.suffix(Self.historyLimit))
        }
    }

    func prepare() throws {
        // Do not recreate a vanished/ejected library root.
        guard (try directory.deletingLastPathComponent().resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
            throw JournalError.invalidHistory
        }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
        catch let error as CocoaError where error.code == .fileWriteFileExists {
            guard (try directory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw error }
        }
    }

    private func update(_ mutation: (inout Document) -> Void) throws {
        try prepare()
        let url = directory.appendingPathComponent((writerID ?? Self.installationID) + ".json")
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { destination in
            do {
                var document: Document
                do { document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: destination)) }
                catch let error as CocoaError where error.code == .fileReadNoSuchFile { document = Document() }
                catch is DecodingError {
                    // A damaged disposable log must not permanently prevent
                    // saving library files. A new incarnation forces readers
                    // with any old cursor to do a full audit.
                    document = Document()
                }
                guard document.version == 1 else { throw JournalError.invalidHistory }
                mutation(&document)
                document.revision = UUID()
                try JSONEncoder().encode(document).write(to: destination, options: .atomic)
            } catch { operationError = error }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }
}
