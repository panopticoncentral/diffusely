import SwiftUI

struct SettingsView: View {
    @StateObject private var apiKeyManager = APIKeyManager.shared
    @ObservedObject private var domainManager = DomainManager.shared
    @State private var apiKeyInput = ""
    @State private var showingAPIKeyInfo = false

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
        .frame(width: 450, height: 280)
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
