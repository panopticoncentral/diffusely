import SwiftUI

struct SettingsView: View {
    @StateObject private var apiKeyManager = APIKeyManager.shared
    @StateObject private var openRouterConfig = OpenRouterConfig.shared
    @ObservedObject private var domainManager = DomainManager.shared
    @ObservedObject private var vaultProvider = LibraryVaultProvider.shared
    @EnvironmentObject private var libraryStore: LibraryStore
    @State private var apiKeyInput = ""
    @State private var openRouterKeyInput = ""
    @State private var showingAPIKeyInfo = false
    @State private var showingResetConfirmation = false
    @State private var showingLibraryEncryption = false
    /// Resume direction for an interrupted migration (or `nil` when complete),
    /// so the row status reads the right way for a partial disable too.
    @State private var libraryEncryptionDirection: LibraryMigrationDirection?
    @State private var cacheLimitGB: Int = 2
    @State private var checkpointReport: CheckpointReportText?
    @State private var isRunningCheckpointReport = false

    private static let cacheLimitOptions = [1, 2, 5, 10, 20]

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        settingsContent
            .alert("Get API Key", isPresented: $showingAPIKeyInfo) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("To get your Civitai API Key:\n\n1. Go to \(domainManager.domain.rawValue)\n2. Sign in to your account\n3. Go to Account Settings\n4. Navigate to the API Keys section\n5. Generate a new API key\n6. Copy and paste it here")
            }
            .alert("Reset Library", isPresented: $showingResetConfirmation) {
                Button("Delete Everything", role: .destructive) {
                    Task { await libraryStore.resetLibrary() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This permanently deletes all \(libraryStore.itemCount) items from your library, including originals in iCloud on all your devices. This cannot be undone.")
            }
            // macOS's Settings scene has no navigation stack to push into, so
            // "Library Encryption" opens as a sheet there; iOS instead uses a
            // plain `NavigationLink` inside the Form (see `formSections`).
            // Declaring the sheet unconditionally (rather than under
            // `#if os(macOS)`) is harmless on iOS: `showingLibraryEncryption`
            // is never set `true` there.
            .sheet(isPresented: $showingLibraryEncryption) {
                NavigationStack {
                    LibraryEncryptionSettingsView(provider: vaultProvider)
                }
            }
            .sheet(item: $checkpointReport) { report in
                CheckpointReportSheet(report: report)
            }
    }

    @ViewBuilder
    private var settingsContent: some View {
        #if os(macOS)
        Form {
            formSections
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 520)
        #else
        NavigationStack {
            Form {
                formSections
            }
            .navigationTitle("Settings")
        }
        #endif
    }

    private var sortAssistantSection: some View {
        Section {
            if openRouterConfig.hasAPIKey {
                HStack {
                    Text("OpenRouter API Key")
                    Spacer()
                    Text("••••••••").foregroundColor(.secondary)
                }
                Button("Remove OpenRouter Key", role: .destructive) {
                    openRouterConfig.apiKey = nil
                    openRouterKeyInput = ""
                }
            } else {
                SecureField("OpenRouter API Key", text: $openRouterKeyInput)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Button("Save Key") {
                    openRouterConfig.apiKey = openRouterKeyInput
                }
                .disabled(openRouterKeyInput.isEmpty)
            }
            TextField("Model", text: $openRouterConfig.model)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        } header: {
            Text("Sort Assistant")
        } footer: {
            Text("The Sort Assistant sends Library item prompts (text only, never images) to this OpenRouter model to suggest albums.")
        }
    }

    @ViewBuilder
    private var formSections: some View {
        Section {
            Picker("Source", selection: $domainManager.domain) {
                ForEach(CivitaiDomain.allCases) { domain in
                    Text(domain.displayName).tag(domain)
                }
            }
        } header: {
            Text("Content Source")
        } footer: {
            Text("civitai.com shows SFW content only (up to PG-13). civitai.red shows mature content (R, X, XXX).")
                .font(.caption)
        }

        Section {
            if apiKeyManager.hasAPIKey {
                HStack {
                    Text("API Key")
                    Spacer()
                    Text("Connected")
                        .foregroundColor(.green)
                }

                Button("Remove API Key", role: .destructive) {
                    apiKeyManager.clearAPIKey()
                    apiKeyInput = ""
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enter your Civitai API Key to access your collections")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    SecureField("API Key", text: $apiKeyInput)
                        .textContentType(.password)
                        #if os(iOS)
                        .autocapitalization(.none)
                        #endif

                    Button("Save API Key") {
                        apiKeyManager.apiKey = apiKeyInput
                    }
                    .disabled(apiKeyInput.isEmpty)
                }
            }
        } header: {
            Text("Authentication")
        } footer: {
            Button("How to get an API Key") {
                showingAPIKeyInfo = true
            }
            .font(.caption)
        }

        sortAssistantSection

        Section {
            HStack {
                Text("iCloud Sync")
                Spacer()
                switch libraryStore.iCloudStatus {
                case .checking:
                    Text("Checking…").foregroundColor(.secondary)
                case .available:
                    Text("On").foregroundColor(.green)
                case .unavailable:
                    Text("Local only").foregroundColor(.orange)
                }
            }

            HStack {
                Text("Downloaded on This Device")
                Spacer()
                // `downloadedBytes` is 0 until the first reconcile + refresh
                // completes; show "Calculating…" rather than a misleading
                // "Zero KB" while the total is still being tallied.
                Text(libraryStore.isReady
                     ? ByteCountFormatter.string(fromByteCount: Int64(libraryStore.downloadedBytes), countStyle: .file)
                     : "Calculating…")
                    .foregroundColor(.secondary)
            }

            Picker("Keep Up To", selection: $cacheLimitGB) {
                ForEach(Self.cacheLimitOptions, id: \.self) { gb in
                    Text("\(gb) GB").tag(gb)
                }
            }
            .onChange(of: cacheLimitGB) { _, newValue in
                libraryStore.cacheLimitBytes = newValue * 1024 * 1024 * 1024
            }

            Button("Free Up Space Now") {
                Task { await libraryStore.freeUpSpaceNow() }
            }

            HStack {
                Button("Rebuild Index") {
                    Task {
                        isRebuildingIndex = true
                        rebuildIndexResult = nil
                        await libraryStore.rebuildIndex()
                        // Read AFTER the await: `rebuildIndex` republishes both
                        // of these, so the summary describes the pass that just
                        // finished rather than the state it started from.
                        let now = Date()
                        rebuildIndexResult = libraryStore.downloadProgress
                            .state(now: now)
                            .rebuildSummary(indexedItems: libraryStore.itemCount, now: now)
                        isRebuildingIndex = false
                    }
                }
                .disabled(!canRebuildIndex || isRebuildingIndex)

                if isRebuildingIndex {
                    ProgressView().controlSize(.small)
                }
            }

            // A rebuild that correctly changes nothing is indistinguishable
            // from one that never ran unless it says so — pressing this twice
            // with no visible response is what sent one debugging session
            // looking for a bug in the index.
            if let rebuildIndexResult {
                Text(rebuildIndexResult)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Explains the disabled state above rather than letting the tap
            // silently no-op against `LibraryStore.rebuildIndex()`'s own gate
            // (mirrors BE-f's "no silent caps" convention).
            if let reason = rebuildIndexUnavailableReason {
                Text(reason)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            #if os(iOS)
            NavigationLink {
                LibraryEncryptionSettingsView(provider: vaultProvider)
            } label: {
                libraryEncryptionRow
            }
            #else
            Button {
                showingLibraryEncryption = true
            } label: {
                libraryEncryptionRow
            }
            .buttonStyle(.plain)
            #endif

            Button("Reset Library", role: .destructive) {
                showingResetConfirmation = true
            }
            .disabled(libraryStore.itemCount == 0)
        } header: {
            Text("Personal Library")
        } footer: {
            Text("Originals are stored in iCloud Drive. This device keeps roughly the selected amount downloaded for fast viewing; iCloud may keep more or less.")
                .font(.caption)
        }
        .onAppear {
            cacheLimitGB = max(1, libraryStore.cacheLimitBytes / (1024 * 1024 * 1024))
        }
        .task(id: vaultProvider.state) {
            libraryEncryptionDirection = await vaultProvider.incompleteMigrationDirection()
        }

        diagnosticsSection

        aboutSection
    }

    // MARK: - Diagnostics

    /// Wrapper so the report can drive `.sheet(item:)` — the text itself has
    /// no identity of its own.
    fileprivate struct CheckpointReportText: Identifiable {
        let id = UUID()
        let text: String
    }

    private var diagnosticsSection: some View {
        Section {
            Button {
                Task { await runCheckpointDiagnostic() }
            } label: {
                HStack {
                    Text("Checkpoint Grouping Report")
                    Spacer()
                    if isRunningCheckpointReport {
                        ProgressView()
                            #if os(macOS)
                            .controlSize(.small)
                            #endif
                    }
                }
            }
            .disabled(isRunningCheckpointReport || vaultProvider.state == .locked)
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Reads every Library sidecar and reports why each item does or doesn't group under a checkpoint — what fills the \"Other\" and \"Videos\" buckets in Checkpoint sort. Read-only; nothing is modified.")
                .font(.caption)
        }
    }

    /// Scans the container off the main actor, cross-checks the index, and
    /// shows the report. Also `print`s it, so a run on a real device can be
    /// read over `devicectl --console` without copying from the sheet.
    private func runCheckpointDiagnostic() async {
        isRunningCheckpointReport = true
        defer { isRunningCheckpointReport = false }
        do {
            let directory = try await LibraryContainer.shared.itemsDirectory()
            let scan = try await LibraryCheckpointDiagnosticsScanner(itemsDirectory: directory).scan()
            let index = await libraryStore.indexService.checkpointIndexSnapshot()
            let report = LibraryCheckpointDiagnostics.report(
                findings: scan.findings,
                indexCheckpointNames: index.names,
                indexedItemIDs: index.ids,
                isEncryptedContainer: scan.isEncrypted,
                unreadableCount: scan.unreadableCount
            )
            print(report.text)
            checkpointReport = CheckpointReportText(text: report.text)
        } catch {
            checkpointReport = CheckpointReportText(text: "Checkpoint diagnostic failed: \(error)")
        }
    }

    /// "Library Encryption" row content shared by the iOS `NavigationLink`
    /// and the macOS sheet-presenting `Button` in `formSections`. Status text
    /// mirrors `LibraryEncryptionSettingsView`'s own section switch (Off /
    /// Finishing setup… / On) so the two never say something different about
    /// the same state.
    private var libraryEncryptionRow: some View {
        HStack {
            Text("Library Encryption")
            Spacer()
            Text(libraryEncryptionStatusText)
                .foregroundColor(libraryEncryptionStatusColor)
        }
    }

    /// Mirrors `LibraryStore.rebuildIndex()`'s own gate so the button is
    /// disabled — not just a silent no-op tap — whenever the store would skip
    /// the rebuild anyway. Derived from `rebuildIndexUnavailableReason` (which
    /// calls the store's own predicate) so the button state and the caption
    /// below it can never disagree: disabled ⇔ a caption explains why.
    /// Live for the duration of one tap: disables the button and shows a
    /// spinner so a rebuild over a large container doesn't look like a no-op.
    @State private var isRebuildingIndex = false

    /// What the last rebuild in this session reported. Cleared at the start of
    /// each run so a stale line never describes a newer pass.
    @State private var rebuildIndexResult: String?

    private var canRebuildIndex: Bool {
        rebuildIndexUnavailableReason == nil
    }

    /// Why "Rebuild Index" is currently unavailable, or `nil` when it's
    /// allowed. The *decision* is delegated to the very predicate
    /// `LibraryStore.rebuildIndex()` guards on, so this can never claim the
    /// button works when the store would skip the rebuild (or vice versa);
    /// the switch below only explains the answer.
    ///
    /// State-specific by design: Settings is reachable in every gate state, and
    /// the vault auto-locks (idle timeout, and on every relaunch), so `.locked`
    /// is the case a user actually hits — telling them Library Encryption is
    /// "finishing setup" then sent one debugging session chasing a migration
    /// that wasn't running. Exhaustive with no `default`, so a new
    /// `LibraryVaultProvider.LibraryGate` case is a compile error here rather
    /// than silently inheriting someone else's explanation.
    private var rebuildIndexUnavailableReason: String? {
        let gate = vaultProvider.libraryGate
        guard !LibraryStore.shouldAutonomousReconcile(givenLibraryGate: gate) else { return nil }
        switch gate {
        case .browsable:
            // Unreachable while the predicate is `gate == .browsable`; kept so
            // this stays correct if it ever widens.
            return nil
        case .loading:
            return "Rebuild Index is unavailable while your Library is still loading."
        case .locked:
            return "Unlock your Library to rebuild the index."
        case .migrating, .setupIncomplete:
            return "Rebuild Index is unavailable while Library Encryption is finishing setup."
        }
    }

    private var libraryEncryptionStatusText: String {
        switch vaultProvider.state {
        case .notConfigured:
            return "Off"
        case .locked, .unlocked:
            switch libraryEncryptionDirection {
            case .enable: return "Finishing setup…"
            case .disable: return "Turning off…"
            case nil: return "On"
            }
        }
    }

    private var libraryEncryptionStatusColor: Color {
        switch vaultProvider.state {
        case .notConfigured:
            return .secondary
        case .locked, .unlocked:
            return libraryEncryptionDirection == nil ? .green : .orange
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(Self.appVersion)
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// Scrollable, copyable presentation of a `LibraryCheckpointDiagnostics`
/// report. Monospaced because the report is column-aligned text.
private struct CheckpointReportSheet: View {
    let report: SettingsView.CheckpointReportText
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                Text(report.text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Checkpoint Grouping")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Copy") { Clipboard.copy(report.text) }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 520)
        #endif
    }
}
