#if os(macOS)
import AppKit

/// Folder picker for choosing where the Library lives. Sibling of
/// `LibraryExportPanel` — same unsandboxed assumption, different wording: this
/// URL is stored and reused across launches rather than used once.
enum LibraryRootPanel {
    @MainActor
    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Open"
        panel.message = "Choose the folder that holds your Library. An empty folder starts a new one."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
#endif
