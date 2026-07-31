import SwiftUI

/// Library at-rest encryption settings: enable (recovery key shown +
/// acknowledged BEFORE any file is migrated), resume an interrupted enable,
/// and manage (change password / turn off) once encryption is on.
///
/// Everything reactive here reads `provider.state` / `provider.migrationPhase`
/// / `provider.libraryGate`, and every action calls one of the provider's
/// gate-aware entry points — `enableConfigure`, `runEnableMigration`,
/// `disableEncryption`, `incompleteMigrationDirection` — never the raw
/// `LibraryEncryptionCoordinator` directly. Those provider methods recompute
/// the Library tab's block gate at the right moments; calling the coordinator
/// straight from this view would bypass that and risk exposing a
/// half-migrated Library. See `LibraryVaultProvider`'s "Enable / disable"
/// section for why.
struct LibraryEncryptionSettingsView: View {
    @ObservedObject var provider: LibraryVaultProvider

    /// The direction a prior interrupted migration should resume in (`.enable`
    /// = a partial enable to finish encrypting; `.disable` = a partial disable
    /// to finish decrypting), or `nil` when there's nothing to resume.
    /// Recomputed via `incompleteMigrationDirection()` whenever `provider.state`
    /// changes and right after every action, since it isn't itself a
    /// `@Published` provider property.
    @State private var incompleteDirection: LibraryMigrationDirection?

    @State private var newPassword = ""
    @State private var confirmPassword = ""

    /// The one-time recovery key returned by `enableConfigure`. Presenting
    /// this drives the recovery-key sheet; it is set to `nil` only once the
    /// user has acknowledged saving it and tapped Continue — never by a
    /// swipe-to-dismiss (the sheet disables interactive dismissal), so
    /// migration can never start before the key has been shown.
    @State private var recoveryKeyToShow: String?
    @State private var acknowledgedRecovery = false

    @State private var showChangePassword = false
    @State private var showDisableConfirmation = false

    @State private var errorMessage: String?
    @State private var busy = false

    #if os(macOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        Form {
            switch provider.state {
            case .notConfigured:
                enableSection
            case .locked, .unlocked:
                if let incompleteDirection {
                    resumeSection(incompleteDirection)
                } else {
                    manageSection
                }
            }

            progressSection

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Library Encryption")
        #if os(macOS)
        .formStyle(.grouped)
        .frame(minWidth: 420, idealWidth: 480)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        #endif
        .task { await provider.bootstrap() }
        .task(id: provider.state) { await refreshIncomplete() }
        .sheet(item: recoveryKeyBinding) { box in
            RecoveryKeySheet(recoveryKey: box.value, acknowledged: $acknowledgedRecovery) {
                // Only reachable once `acknowledged` is true (Continue is
                // disabled until then) — this is the one and only place
                // `runMigration()` is triggered from the enable path, so
                // configure → show key → acknowledge → migrate is enforced
                // by construction, not just by convention.
                recoveryKeyToShow = nil
                Task { await runMigration() }
            }
        }
        .sheet(isPresented: $showChangePassword) {
            ChangeLibraryPasswordView(provider: provider)
        }
        .confirmationDialog(
            "Turn off encryption?",
            isPresented: $showDisableConfirmation,
            titleVisibility: .visible
        ) {
            Button("Turn Off Encryption", role: .destructive) { Task { await disable() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This decrypts your entire Library back to plaintext on disk. It can take a while and downloads every saved item once.")
        }
    }

    // MARK: - Enable

    private var enableSection: some View {
        Section {
            Text("**Update this app on all your devices first.** Turning it on downloads every saved item once and re-encrypts your whole Library.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            SecureField("Password", text: $newPassword)
                .textContentType(.newPassword)
            SecureField("Confirm password", text: $confirmPassword)
                .textContentType(.newPassword)
            Button {
                Task { await enable() }
            } label: {
                if busy {
                    ProgressView()
                } else {
                    Text("Encrypt Library")
                }
            }
            .disabled(busy || migrationActive || newPassword.isEmpty || newPassword != confirmPassword)
        } header: {
            Text("Turn on encryption")
        }
    }

    private func enable() async {
        errorMessage = nil
        busy = true
        defer { busy = false }
        do {
            let key = try await provider.enableConfigure(password: newPassword)
            newPassword = ""
            confirmPassword = ""
            // `enableConfigure` only recomputes the coarse gate; flip the
            // published `state` too so this view (and a re-opened Settings
            // screen) correctly show Resume instead of Enable from here on.
            await provider.refreshState()
            acknowledgedRecovery = false
            recoveryKeyToShow = key
        } catch {
            errorMessage = legibleMessage(for: error, action: "turn on encryption")
        }
    }

    // MARK: - Resume

    @ViewBuilder
    private func resumeSection(_ direction: LibraryMigrationDirection) -> some View {
        Section("Encryption") {
            switch direction {
            case .enable:
                Label("Encryption setup didn't finish", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Your Library is partly encrypted. Your recovery key was already shown and won't be shown again — resume to finish.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .disable:
                Label("Encryption is still turning off", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Your Library is partly decrypted. Resume to finish turning encryption off.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await resume(direction) }
            } label: {
                if busy {
                    ProgressView()
                } else {
                    Text("Resume")
                }
            }
            .disabled(busy || migrationActive)
        }
    }

    /// Resume an interrupted migration in the correct direction: `.enable`
    /// re-runs the forward migration (`runEnableMigration()`), `.disable`
    /// continues the reverse migration + teardown (`disableEncryption()`).
    /// Routing on the persisted direction (not just forward-pending count) is
    /// what keeps a resumed disable from re-encrypting the Library.
    private func resume(_ direction: LibraryMigrationDirection) async {
        switch direction {
        case .enable:
            await runMigration()
        case .disable:
            await disable()
        }
    }

    /// Shared by the recovery-key sheet's "Continue" (first-time enable) and
    /// the Resume button (a later session picking up an interrupted enable).
    /// Both call the same provider entry point, `runEnableMigration()` — the
    /// recovery key is never involved here, matching "shown once, never
    /// re-shown".
    private func runMigration() async {
        errorMessage = nil
        busy = true
        defer { busy = false }
        do {
            try await provider.runEnableMigration()
            await provider.refreshState()
        } catch {
            errorMessage = legibleMessage(for: error, action: "finish encryption setup")
        }
        await refreshIncomplete()
    }

    // MARK: - Manage

    private var manageSection: some View {
        Section("Encryption is on") {
            // Available whether locked or unlocked: `vault.changePassword`
            // re-derives the key from the old password internally, so it
            // doesn't need a cached DEK.
            Button("Change password…") { showChangePassword = true }
                .disabled(busy || migrationActive)

            if provider.state == .unlocked {
                Button("Turn off encryption", role: .destructive) {
                    showDisableConfirmation = true
                }
                .disabled(busy || migrationActive)
            } else {
                // `disableEncryption()` needs the cached DEK (guards on
                // `vault.crypto()`), which a `.locked` vault doesn't have —
                // don't offer a live Disable action that can only fail.
                Text("Unlock the Library to turn off encryption.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func disable() async {
        errorMessage = nil
        busy = true
        defer { busy = false }
        do {
            try await provider.disableEncryption()
            await provider.refreshState()
        } catch LibraryVaultError.wrongCredential {
            // The UI already hides this action while `.locked` (see
            // `manageSection`); this only fires if the vault locked out from
            // under the view between opening the confirmation and this call
            // completing. `disableEncryption()`'s only source of
            // `.wrongCredential` is the coordinator's locked-vault guard —
            // never a user-entered password (this flow doesn't collect one)
            // — so the generic "password is incorrect" copy would be wrong.
            errorMessage = "Unlock the Library before turning off encryption."
        } catch {
            errorMessage = legibleMessage(for: error, action: "turn off encryption")
        }
        await refreshIncomplete()
    }

    // MARK: - Progress

    @ViewBuilder
    private var progressSection: some View {
        switch provider.migrationPhase {
        case .idle:
            EmptyView()
        case let .encrypting(done, total):
            progress("Encrypting", done: done, total: total)
        case let .decrypting(done, total):
            progress("Decrypting", done: done, total: total)
        case .failed:
            // Deliberately not the raw `.failed(String)` payload — that's
            // `String(describing: error)` from the coordinator, an internal
            // system string, not something to show a user. Direction-aware so a
            // failed DISABLE isn't described as a failed enable setup.
            Section {
                Text(failedMessage)
                    .foregroundStyle(.red)
            }
        }
    }

    private func progress(_ label: String, done: Int, total: Int) -> some View {
        Section {
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text("\(label)… \(done)/\(total)")
            }
        }
    }

    /// Copy for the `.failed` progress section, keyed on the resume direction
    /// so a failed turn-off isn't mislabeled as a failed setup.
    private var failedMessage: String {
        switch incompleteDirection {
        case .disable:
            return "Turning off encryption didn't finish. Your Library is safe — nothing was lost. Tap Resume to try again."
        case .enable, nil:
            return "Encryption setup didn't finish. Your Library is safe — nothing was lost. Tap Resume to try again."
        }
    }

    private var migrationActive: Bool {
        switch provider.migrationPhase {
        case .encrypting, .decrypting: return true
        case .idle, .failed: return false
        }
    }

    // MARK: - Helpers

    private func refreshIncomplete() async {
        incompleteDirection = await provider.incompleteMigrationDirection()
    }

    private var recoveryKeyBinding: Binding<RecoveryKeyBox?> {
        Binding(
            get: { recoveryKeyToShow.map(RecoveryKeyBox.init) },
            set: { recoveryKeyToShow = $0?.value }
        )
    }
}

/// Translates thrown errors into copy a user can act on, never a raw
/// system/error description. File-scope (rather than a method on
/// `LibraryEncryptionSettingsView`) so `ChangeLibraryPasswordView` shares the
/// same mapping instead of rolling its own — in particular so a corrupt-vault
/// `.malformed` there isn't misreported as a wrong password.
///
/// `.wrongCredential` reads as "That password is incorrect." here because
/// every current call site that can throw it in a context reaching this
/// helper actually collected a password from the user (enable/resume don't
/// throw it in practice, and `changePassword` throws it for a genuinely wrong
/// old password). `disable()`'s locked-vault `.wrongCredential` — where no
/// password was collected — is special-cased in its own catch clause instead
/// of going through this helper; see `LibraryEncryptionSettingsView.disable()`.
private func legibleMessage(for error: Error, action: String) -> String {
    if let vaultError = error as? LibraryVaultError {
        switch vaultError {
        case .wrongCredential:
            return "That password is incorrect."
        case .malformed:
            return "The Library's encryption data appears to be damaged. Please try again."
        }
    }
    return "Couldn't \(action). Check your connection and available storage, then try again."
}

private struct RecoveryKeyBox: Identifiable {
    let value: String
    var id: String { value }
}

/// Shown exactly once, right after `enableConfigure` succeeds and before any
/// migration runs. Interactive dismissal is disabled — the only way out is
/// "Continue", which is itself disabled until the user acknowledges the
/// toggle — so the key can't be swiped away unread and migration can't start
/// unacknowledged.
private struct RecoveryKeySheet: View {
    let recoveryKey: String
    @Binding var acknowledged: Bool
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "key.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text("Save Your Recovery Key")
                .font(.headline)

            Text("This is the **only** way back into your Library if you forget your password. It is shown once and can't be shown again.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Text(recoveryKey)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            Button("Copy") { Clipboard.copy(recoveryKey) }

            Toggle("I've saved my recovery key somewhere safe", isOn: $acknowledged)

            Button("Continue") { onContinue() }
                .buttonStyle(.borderedProminent)
                .disabled(!acknowledged)
        }
        .padding()
        .frame(maxWidth: 420)
        .interactiveDismissDisabled()
    }
}

/// Old/new/confirm subview for `vault.changePassword(old:new:)`. Reaches the
/// vault directly through `provider.vault` (per the addendum: this doesn't
/// affect the Library gate, so no provider passthrough is needed for it).
private struct ChangeLibraryPasswordView: View {
    @ObservedObject var provider: LibraryVaultProvider
    @Environment(\.dismiss) private var dismiss

    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Current password", text: $oldPassword)
                        .textContentType(.password)
                    SecureField("New password", text: $newPassword)
                        .textContentType(.newPassword)
                    SecureField("Confirm new password", text: $confirmPassword)
                        .textContentType(.newPassword)
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Change Password")
            #if os(macOS)
            .formStyle(.grouped)
            .frame(minWidth: 360, idealWidth: 420)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(oldPassword.isEmpty || newPassword.isEmpty || newPassword != confirmPassword)
                    }
                }
            }
        }
    }

    private func save() async {
        errorMessage = nil
        guard let vault = provider.vault else {
            errorMessage = "Library isn't ready yet. Please try again."
            return
        }
        busy = true
        defer { busy = false }
        do {
            try await vault.changePassword(old: oldPassword, new: newPassword)
            dismiss()
        } catch {
            errorMessage = legibleMessage(for: error, action: "change the password")
        }
    }
}
