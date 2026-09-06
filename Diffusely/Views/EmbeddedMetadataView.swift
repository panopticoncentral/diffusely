import SwiftUI

/// Displays generation metadata read directly from the image file, below the Civitai
/// "Generation Info". A1111 renders as prompt/negative/fields; ComfyUI as a recipe of
/// passes; the verbatim string is always available under a collapsible Raw disclosure.
struct EmbeddedMetadataView: View {
    let metadata: EmbeddedMetadata
    let itemID: Int
    let loadOriginalBytes: () async -> Data?

    @State private var rawCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Embedded Metadata")
                .font(.headline)
                .foregroundColor(.primary)

            switch metadata.format {
            case .automatic1111:
                if let params = metadata.parameters {
                    if let prompt = params.prompt, !prompt.isEmpty {
                        CopyablePromptView(label: "Prompt", text: prompt)
                    }
                    if let negative = params.negativePrompt, !negative.isEmpty {
                        CopyablePromptView(label: "Negative Prompt", text: negative)
                    }
                    if !params.fields.isEmpty {
                        MetadataFieldGrid(fields: params.fields)
                    }
                }
            case .comfyUI:
                if let comfy = metadata.comfy {
                    ComfyRecipeView(payload: comfy, itemID: itemID, loadOriginalBytes: loadOriginalBytes)
                }
            case .unknown:
                EmptyView()
            }

            DisclosureGroup("Raw") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Spacer()
                        Button {
                            Clipboard.copy(metadata.raw)
                            withAnimation { rawCopied = true }
                            Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                withAnimation { rawCopied = false }
                            }
                        } label: {
                            Label(rawCopied ? "Copied" : "Copy",
                                  systemImage: rawCopied ? "checkmark" : "doc.on.doc")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .disabled(rawCopied)
                    }
                    Text(metadata.raw)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
            .font(.subheadline)
        }
    }
}
