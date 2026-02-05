import SwiftUI

struct SyncProgressView: View {
    let progress: CollectionSyncService.SyncProgress

    var body: some View {
        HStack(spacing: 8) {
            if !progress.isComplete && progress.lastError == nil {
                ProgressView()
                    .scaleEffect(0.8)
            } else if progress.isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 14))
            } else if progress.lastError != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 14))
            }

            if let error = progress.lastError {
                Text("Sync error")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else if progress.isComplete {
                Text("Synced \(progress.itemsFetched) items")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Syncing... \(progress.itemsFetched) items")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }
}
