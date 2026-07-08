#if os(macOS)
import SwiftUI
import Quartz

/// Bridges a SwiftUI view to the shared `QLPreviewPanel`. Point `urls` at the
/// files to preview and flip `isPresented` to open the panel; `onClose` fires
/// when the user dismisses it so the caller can reset its state.
///
/// `QLPreviewPanel` drives itself through the responder chain (its required
/// control protocol), so the backing `NSView` becomes first responder when it
/// opens the panel and implements the three control methods.
struct QuickLookHost: NSViewRepresentable {
    var urls: [URL]
    @Binding var isPresented: Bool
    var onClose: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ControlView {
        let view = ControlView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ControlView, context: Context) {
        context.coordinator.urls = urls
        context.coordinator.onClose = onClose
        nsView.coordinator = context.coordinator
        if isPresented {
            nsView.present()
        } else {
            nsView.dismiss()
        }
    }

    final class Coordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
        var urls: [URL] = []
        var onClose: () -> Void = {}

        func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int { urls.count }

        func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem {
            let url = urls.indices.contains(index) ? urls[index] : (urls.first ?? URL(fileURLWithPath: "/"))
            return url as NSURL
        }
    }

    final class ControlView: NSView {
        weak var coordinator: Coordinator?

        func present() {
            guard let panel = QLPreviewPanel.shared() else { return }
            // Nudge iCloud to materialize the files so QuickLook has bytes to
            // render (no-op for already-downloaded or local items).
            for url in coordinator?.urls ?? [] {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
            window?.makeFirstResponder(self)
            if panel.isVisible {
                panel.reloadData()
            } else {
                panel.makeKeyAndOrderFront(nil)
            }
        }

        func dismiss() {
            guard QLPreviewPanel.sharedPreviewPanelExists(),
                  let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
            panel.orderOut(nil)
        }

        // MARK: QLPreviewPanel control (responder-chain protocol)

        override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel) -> Bool { true }

        override func beginPreviewPanelControl(_ panel: QLPreviewPanel) {
            panel.dataSource = coordinator
            panel.delegate = coordinator
            panel.reloadData()
        }

        override func endPreviewPanelControl(_ panel: QLPreviewPanel) {
            panel.dataSource = nil
            panel.delegate = nil
            coordinator?.onClose()
        }
    }
}
#endif
