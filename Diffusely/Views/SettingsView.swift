import SwiftUI

struct SettingsView: View {
    @StateObject private var apiKeyManager = APIKeyManager.shared
    @ObservedObject private var domainManager = DomainManager.shared
    @EnvironmentObject private var libraryStore: LibraryStore
    @State private var apiKeyInput = ""
    @State private var showingAPIKeyInfo = false
    @State private var cacheLimitGB: Int = 2

    private static let cacheLimitOptions = [1, 2, 5, 10, 20]

    var body: some View {
        settingsContent
            .alert("Get API Key", isPresented: $showingAPIKeyInfo) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("To get your Civitai API Key:\n\n1. Go to \(domainManager.domain.rawValue)\n2. Sign in to your account\n3. Go to Account Settings\n4. Navigate to the API Keys section\n5. Generate a new API key\n6. Copy and paste it here")
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

        Section {
            HStack {
                Text("iCloud Sync")
                Spacer()
                Text(libraryStore.isICloudBacked ? "On" : "Local only")
                    .foregroundColor(libraryStore.isICloudBacked ? .green : .orange)
            }

            HStack {
                Text("Downloaded on This Device")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(libraryStore.downloadedBytes), countStyle: .file))
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

            Button("Rebuild Index") {
                Task { await libraryStore.rebuildIndex() }
            }
        } header: {
            Text("Personal Library")
        } footer: {
            Text("Originals are stored in iCloud Drive. This device keeps roughly the selected amount downloaded for fast viewing; iCloud may keep more or less.")
                .font(.caption)
        }
        .onAppear {
            cacheLimitGB = max(1, libraryStore.cacheLimitBytes / (1024 * 1024 * 1024))
        }

        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text("1.0.0")
                    .foregroundColor(.secondary)
            }
        }
    }
}
