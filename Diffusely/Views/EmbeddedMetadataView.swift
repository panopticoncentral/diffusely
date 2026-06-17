import SwiftUI

/// Displays generation metadata read directly from the image file, below the Civitai
/// "Generation Info". A1111-parsed fields render structured; the verbatim string is
/// always available under a collapsible Raw disclosure.
struct EmbeddedMetadataView: View {
    let metadata: EmbeddedMetadata

    @State private var rawCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Embedded Metadata")
                .font(.headline)
                .foregroundColor(.primary)

            if let params = metadata.parameters {
                if let prompt = params.prompt, !prompt.isEmpty {
                    CopyablePromptView(label: "Prompt", text: prompt)
                }
                if let negative = params.negativePrompt, !negative.isEmpty {
                    CopyablePromptView(label: "Negative Prompt", text: negative)
                }
                if !params.fields.isEmpty {
                    fieldGrid(params.fields)
                }
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

    @ViewBuilder
    private func fieldGrid(_ fields: [GenerationParameters.Field]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
            ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                GridRow {
                    Text(field.key)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .gridColumnAlignment(.leading)
                    Text(field.value)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
