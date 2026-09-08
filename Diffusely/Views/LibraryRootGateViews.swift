import SwiftUI

/// Blocks the Library while a root switch runs. Inert by construction: it
/// touches neither the store nor any image request, because the old root is
/// quiesced and the new one isn't indexed yet.
struct LibraryRootSwitchingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Switching Library…")
                .font(.headline)
            Text("Rebuilding the index for the new location.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown when the saved custom root isn't there — an unplugged volume, a renamed
/// folder — or when a switch failed partway.
///
/// Deliberately a dead end with two explicit exits rather than a silent fallback
/// to iCloud: reconciling against a missing root would prune the index to
/// nothing, and quietly showing a different Library than the one the user chose
/// is its own kind of data loss.
struct LibraryRootUnavailableView: View {
    /// The missing folder, or `nil` when the failure names no folder of the
    /// user's — a switch back to iCloud that failed has no chosen path to
    /// report, and inventing one ("/") produced a "Library not found at /"
    /// message inviting the user to Locate… a folder they never picked.
    let path: String?
    /// Both return a user-facing error message, or nil on success/cancel. The
    /// view owns the error surface because this gate is a dead end - there is
    /// no other UI on screen to report a failed recovery through.
    let onLocate: () async -> String?
    let onUseICloud: () async -> String?

    @State private var errorMessage: String?
    @State private var isWorking = false

    nonisolated static func title(forPath path: String?) -> String {
        path == nil ? "Library Unavailable" : "Library Not Found"
    }

    nonisolated static func message(forPath path: String?) -> String {
        guard let path else {
            return "Diffusely couldn't open your Library."
        }
        return "Library not found at \(path)."
    }

    nonisolated static func detail(forPath path: String?) -> String {
        guard path != nil else {
            return "Nothing has been changed or deleted. Choose a folder, or try iCloud again."
        }
        return "The folder may be on a disk that isn't connected. Nothing has been changed or deleted."
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 34))
                .foregroundColor(.secondary)
            Text(Self.title(forPath: path))
                .font(.headline)
            Text(Self.message(forPath: path))
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Text(Self.detail(forPath: path))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button("Locate…") { run(onLocate) }
                Button("Switch Back to iCloud") { run(onUseICloud) }
            }
            .disabled(isWorking)
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func run(_ action: @escaping () async -> String?) {
        isWorking = true
        Task {
            errorMessage = await action()
            isWorking = false
        }
    }
}
