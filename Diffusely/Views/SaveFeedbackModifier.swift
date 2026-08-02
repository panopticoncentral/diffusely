import SwiftUI

/// App-level presenter for `LibrarySaveService` failures. Applied once at the
/// ContentView root (per platform branch) so it covers every "Save to Library"
/// call site — the feed cell, image detail, post detail, and author grid — all
/// of which fire through the shared `LibrarySaveService.shared` singleton.
///
/// Those failures set `LibrarySaveService.lastError` but nothing rendered it
/// before. This modifier surfaces every save failure as an alert. The
/// locked-vault case additionally offers to unlock: its "Unlock" button
/// presents the existing `LibraryUnlockView` in a sheet, and on a successful
/// unlock the save(s) the user attempted re-fire automatically.
///
/// Pending retries live in `LibrarySaveService.pendingLockedSaves` — a property
/// independent of `lastError` — so the alert's `isPresented` binding can clear
/// `lastError` on any dismissal without ever dropping a queued retry.
struct SaveFeedbackModifier: ViewModifier {
    @ObservedObject private var saveService = LibrarySaveService.shared
    private let vaultProvider = LibraryVaultProvider.shared
    @State private var showUnlockSheet = false

    func body(content: Content) -> some View {
        content
            .alert(
                saveService.lastError?.alertTitle ?? "",
                isPresented: errorPresented,
                presenting: saveService.lastError
            ) { error in
                if error.isLibraryLocked {
                    Button("Unlock") { showUnlockSheet = true }
                    Button("Not Now", role: .cancel) {
                        saveService.discardPendingLockedSaves()
                    }
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { error in
                Text(error.errorDescription ?? "")
            }
            .sheet(isPresented: $showUnlockSheet, onDismiss: {
                // Idempotent cleanup: after a successful unlock the retry has
                // already drained the queue (no-op here); after a swipe-dismiss
                // this drops the queued save.
                saveService.discardPendingLockedSaves()
            }) {
                SaveUnlockSheet(
                    provider: vaultProvider,
                    onUnlocked: {
                        saveService.retryPendingLockedSaves()
                        showUnlockSheet = false
                    },
                    onCancel: { showUnlockSheet = false }
                )
            }
    }

    /// Drives the alert off `lastError`; clears only the error on dismissal so
    /// the retry queue survives for the Unlock path.
    private var errorPresented: Binding<Bool> {
        Binding(
            get: { saveService.lastError != nil },
            set: { presented in if !presented { saveService.clearError() } }
        )
    }
}

/// The unlock sheet shown from a locked-vault save. Wraps the existing,
/// unmodified `LibraryUnlockView` and watches the vault state: when it flips
/// off `.locked`, `onUnlocked` fires (replaying the queued save and closing the
/// sheet). `LibraryUnlockView`'s own `.task` auto-attempts Face ID / Touch ID
/// on appear, so no unlock logic is duplicated here.
private struct SaveUnlockSheet: View {
    @ObservedObject var provider: LibraryVaultProvider
    let onUnlocked: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            LibraryUnlockView(provider: provider)
                .navigationTitle("Unlock Library")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { onCancel() }
                    }
                }
        }
        .onChange(of: provider.state) { _, newState in
            if newState != .locked { onUnlocked() }
        }
    }
}

extension View {
    /// Attaches the app-level save-failure alert + unlock sheet. Apply once at
    /// the app root; every `LibrarySaveService.shared` call site is covered.
    func saveFeedback() -> some View {
        modifier(SaveFeedbackModifier())
    }
}
