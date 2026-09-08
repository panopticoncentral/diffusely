import SwiftUI

/// Settings row for the Library's location. macOS only: choosing an arbitrary
/// folder needs an unsandboxed `NSOpenPanel`, which iOS has no equivalent of
/// without security-scoped bookmark plumbing through every Library read/write.
struct LibraryLocationRow: View {
    @ObservedObject var libraryStore: LibraryStore
    /// Observed (not owned) so this row re-renders whenever a switch — driven
    /// from here, or from the Library tab's "Locate…" / "Switch Back to
    /// iCloud" recovery while Settings happens to be open — moves the gate.
    /// `root` below is read fresh on every body evaluation rather than cached
    /// in `@State`, so there is exactly one source of truth for "what root is
    /// this row showing" and it can never go stale relative to
    /// `SettingsView.isCustomRoot`, which re-derives the same way.
    @ObservedObject private var vaultProvider = LibraryVaultProvider.shared
    @State private var errorMessage: String?
    @State private var pendingFolder: URL?

    private var root: LibraryRoot { LibraryRootStore.standard.load() }

    /// A switch is running right now. Both buttons below are disabled while it
    /// is: the coordinator rejects a second concurrent switch outright, so
    /// leaving them live would just produce an error the user didn't earn —
    /// and this row and the Library tab's recovery gate are both on screen at
    /// once on macOS, which is exactly how a second click gets made.
    private var isSwitching: Bool { vaultProvider.libraryGate == .switchingRoot }

    nonisolated static func displayName(for root: LibraryRoot) -> String {
        switch root {
        case .iCloud: return "iCloud Drive"
        case .custom(let url): return url.path
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Library Location")
                Spacer()
                Text(Self.displayName(for: root))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                Button("Choose Folder…") { chooseFolder() }
                    .disabled(isSwitching)
                Button("Use iCloud") { switchTo(.iCloud) }
                    .disabled(!root.isCustom || isSwitching)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            if root.isCustom {
                Text("This Library is stored as plain files in the folder above. In-app encryption is available only in iCloud.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .confirmationDialog(
            "Switch Library location?",
            isPresented: Binding(get: { pendingFolder != nil },
                                 set: { if !$0 { pendingFolder = nil } })
        ) {
            Button("Switch and Rebuild Index") {
                if let pendingFolder { switchTo(.custom(pendingFolder)) }
                pendingFolder = nil
            }
            Button("Cancel", role: .cancel) { pendingFolder = nil }
        } message: {
            Text("The index will be rebuilt for the new folder now. In-app encryption isn't available outside iCloud. Nothing is moved or deleted — your current Library stays where it is.")
        }
    }

    private func chooseFolder() {
        errorMessage = nil
        #if os(macOS)
        Task {
            // Pick + validate go through the shared seam (Task 9); the
            // confirmation below is what Settings adds on top of it.
            switch await LibraryLocationSwitcher.chooseFolder() {
            case .cancelled:
                break
            case .rejected(let message):
                errorMessage = message
            case .chosen(let url):
                pendingFolder = url
            }
        }
        #endif
    }

    private func switchTo(_ target: LibraryRoot) {
        errorMessage = nil
        #if os(macOS)
        Task {
            errorMessage = await LibraryLocationSwitcher.apply(target, store: libraryStore)
            // `root` is computed from `LibraryRootStore.standard.load()`, so
            // there's nothing to re-read here: whatever the coordinator left
            // persisted (a completed switch, or the prior root on failure)
            // is exactly what the next body evaluation will show.
        }
        #endif
    }
}
