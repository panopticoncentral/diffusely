import SwiftUI

struct SyncProgressView: View {
    let progress: CollectionSyncService.SyncProgress
    /// When set and the sync is in its error state, the whole row becomes a
    /// tappable retry affordance.
    var onRetry: (() -> Void)? = nil

    /// True when there's a failure to retry and a handler to run.
    private var isRetryable: Bool {
        progress.lastError != nil && progress.retryState == nil && onRetry != nil
    }

    var body: some View {
        if isRetryable {
            Button { onRetry?() } label: { rowContent }
                .buttonStyle(.plain)
                .accessibilityLabel("Sync error. Tap to retry.")
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            if progress.retryState != nil {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14))
            } else if !progress.isComplete && progress.lastError == nil {
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

            if progress.retryState != nil {
                Text("Sync paused — retrying…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if progress.lastError != nil {
                Text(isRetryable ? "Sync error — tap to retry" : "Sync error")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else if progress.isComplete {
                Text("Synced \(progress.itemsFetched) items")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Syncing… \(progress.itemsFetched) items")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(Color(.secondarySystemBackground))
    }
}
