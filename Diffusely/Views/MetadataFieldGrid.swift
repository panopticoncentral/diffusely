import SwiftUI

/// Two-column key/value grid used by every embedded-metadata format.
struct MetadataFieldGrid: View {
    let fields: [GenerationParameters.Field]

    var body: some View {
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
