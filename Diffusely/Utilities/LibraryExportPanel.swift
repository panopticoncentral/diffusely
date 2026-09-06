#if os(macOS)
import AppKit

/// Folder picker for the Library export. The app is not sandboxed (the
/// entitlements file carries only iCloud keys), so the chosen URL stays usable
/// for the whole run with no security-scoped bookmark dance.
enum LibraryExportPanel {
    @MainActor
    static func chooseDestination() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a folder for the exported library."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
#endif
