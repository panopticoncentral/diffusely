import SwiftUI

/// Locked-library gate. Shown by `LibraryView` whenever
/// `LibraryVaultProvider.state` is `.locked`; offers password, Face ID/Touch
/// ID, and recovery-key affordances to unlock the vault.
///
/// On success this view's only responsibility is `await provider.refreshState()`
/// — that recomputes `provider.state`, and the caller's gate (driven by that
/// published state) flips to the unlocked content on its own. This view never
/// pokes `LibraryView` directly.
struct LibraryUnlockView: View {
    @ObservedObject var provider: LibraryVaultProvider

    @State private var password = ""
    @State private var recoveryMode = false
    @State private var recoveryKey = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Library Locked")
                .font(.headline)

            if recoveryMode {
                TextField("Recovery key", text: $recoveryKey)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                Button("Unlock with recovery key") {
                    Task { await unlock(recovery: true) }
                }
                .disabled(busy || recoveryKey.isEmpty)

                Button("Back") {
                    recoveryMode = false
                    recoveryKey = ""
                    error = nil
                }
                .font(.footnote)
            } else {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)

                Button("Unlock") {
                    Task { await unlock(recovery: false) }
                }
                .disabled(busy || password.isEmpty)

                Button("Use Face ID") {
                    Task { await biometrics() }
                }
                .disabled(busy)

                Button("Forgot password? Use recovery key") {
                    recoveryMode = true
                    error = nil
                }
                .font(.footnote)
            }

            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
        }
        .padding()
        .frame(maxWidth: 320)
        .task { await biometrics() }
    }

    /// Auto-attempted on appear, and re-attempted from the "Use Face ID"
    /// button. Must never crash or loop: `provider.vault` is `nil` until
    /// `LibraryVaultProvider.bootstrap()` completes (production singleton
    /// path), so this guards and simply stays on the password field rather
    /// than force-unwrapping. Once a vault exists,
    /// `unlockWithBiometrics()` itself already reports "not configured" /
    /// "biometrics unavailable or not enrolled" / "user cancelled" as a
    /// plain `false` rather than throwing, so no do/catch is needed here.
    private func biometrics() async {
        guard let vault = provider.vault else { return }
        busy = true
        if await vault.unlockWithBiometrics() {
            await provider.refreshState()
        }
        busy = false
    }

    private func unlock(recovery: Bool) async {
        guard let vault = provider.vault else {
            error = "Library isn't ready yet. Please try again."
            return
        }
        busy = true
        error = nil
        do {
            if recovery {
                try await vault.unlock(recoveryKey: recoveryKey)
            } else {
                try await vault.unlock(password: password)
            }
            await provider.refreshState()
        } catch {
            self.error = "Incorrect \(recovery ? "recovery key" : "password")."
        }
        busy = false
    }
}
