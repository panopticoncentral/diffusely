import SwiftUI

/// A readable vertical detail on phones and an optional inspector on wide windows.
struct MediaDetailLayout<Media: View, Details: View>: View {
    @AppStorage("detailSideBySide") private var sideBySide = true
    @ViewBuilder var media: (CGFloat) -> Media
    @ViewBuilder var details: () -> Details

    var body: some View {
        GeometryReader { geometry in
            Group {
                if geometry.size.width >= 900 && sideBySide {
                    HStack(spacing: 0) {
                        media(geometry.size.height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        ScrollView {
                            details().padding(AppUI.contentMargin)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(width: 340)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            media(geometry.size.height)
                            details()
                                .padding(AppUI.contentMargin)
                                .frame(maxWidth: AppUI.readingWidth, alignment: .leading)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .toolbar {
                if geometry.size.width >= 900 {
                    ToolbarItem(placement: .primaryAction) {
                        Button { sideBySide.toggle() } label: {
                            Label("Toggle Inspector", systemImage: "sidebar.right")
                        }
                        .help(sideBySide ? "Show details below image" : "Show details beside image")
                    }
                }
            }
        }
        .background(Color(.systemBackground))
    }
}

struct SaveMediaButton: View {
    let image: CivitaiImage
    var save: (() -> Void)? = nil
    @ObservedObject private var service = LibrarySaveService.shared

    var body: some View {
        Button {
            if let save { save() } else { service.save(image) }
        } label: {
            if service.isSaving(itemID: image.id) {
                ProgressView().controlSize(.small).accessibilityLabel("Saving to Library")
            } else {
                Label(service.isSaved(itemID: image.id) ? "Saved to Library" : "Save to Library",
                      systemImage: service.isSaved(itemID: image.id) ? "checkmark" : "square.and.arrow.down")
            }
        }
        .disabled(service.isSaving(itemID: image.id) || service.isSaved(itemID: image.id))
        .help(service.isSaved(itemID: image.id) ? "Saved to Library" : "Save to Library")
    }
}
