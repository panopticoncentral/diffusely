import SwiftUI

/// Shared visual rules; touch and pointer controls retain their native sizing.
enum AppUI {
    static let cornerRadius: CGFloat = 10
    static let gridSpacing: CGFloat = 12
    static let contentMargin: CGFloat = 16
    static let readingWidth: CGFloat = 720
}

struct SettingsAccessButton: View {
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #else
    @State private var presented = false
    #endif
    var title = "Settings"

    var body: some View {
        Button {
            #if os(macOS)
            openSettings()
            #else
            presented = true
            #endif
        } label: {
            Label(title, systemImage: "gearshape")
        }
        .help("Open Settings")
        #if os(iOS)
        .sheet(isPresented: $presented) { SettingsView() }
        #endif
    }
}

struct ModeControl<Selection: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Selection
    @ViewBuilder var options: () -> Options

    var body: some View {
        Picker(title, selection: $selection, content: options)
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .padding(.horizontal, AppUI.contentMargin)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
    }
}

struct FeedStatusView: View {
    let videos: Bool
    let error: Error?
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(error == nil ? "No \(videos ? "Videos" : "Images")" : "Couldn't Load \(videos ? "Videos" : "Images")",
                  systemImage: error == nil ? (videos ? "video" : "photo") : "wifi.exclamationmark")
        } description: {
            Text(error == nil ? "Try a different time period or sort order." : "Check your connection and try again.")
        } actions: {
            Button("Retry", action: retry).buttonStyle(.bordered)
        }
    }
}

extension View {
    @ViewBuilder
    func comfortableHitTarget() -> some View {
        #if os(iOS)
        frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        #else
        frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
        #endif
    }
}

extension String {
    func matchesSearch(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        return words.allSatisfy { localizedStandardContains(String($0)) }
    }
}

extension LibraryRoot {
    func deletionMessage(plural: Bool, localOnly: Bool = false) -> String {
        let copies = plural ? "these saved copies and their metadata" : "this saved copy and its metadata"
        switch self {
        case .custom(let url):
            return "This permanently deletes \(copies) from \(url.lastPathComponent). This cannot be undone."
        case .iCloud:
            return localOnly
                ? "This permanently deletes \(copies) from this device. This cannot be undone."
                : "This permanently deletes \(copies) from iCloud and your synced devices. This cannot be undone."
        }
    }
}

extension PersistedLibraryItem {
    var mediaAccessibilityLabel: String {
        let author = authorUsername.map { " by \($0)" } ?? ""
        return "\(isVideo ? "Video" : "Image")\(author), saved \(savedAt.formatted(date: .abbreviated, time: .omitted)), item \(itemID)"
    }

    func matchesSearch(_ query: String) -> Bool {
        "\(itemID) \(authorUsername ?? "") \(checkpointName ?? "") \(mediaType)".matchesSearch(query)
    }
}
