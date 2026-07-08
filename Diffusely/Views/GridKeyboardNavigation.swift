#if os(macOS)
import SwiftUI

/// Roaming keyboard focus for a grid (macOS). The container captures the arrow
/// keys to move a focus index, Return activates the focused item, and — when a
/// `quickLook` handler is supplied — Space previews it. The caller owns
/// `focusedIndex`, draws the focus ring on the matching cell, and scrolls it
/// into view; this modifier only turns key events into index changes, so the
/// same logic serves both the uniform Library grid (2-D, `columns` > 1) and the
/// masonry feed (linear, `columns == 1`).
private struct GridKeyboardNavigation: ViewModifier {
    let count: Int
    let columns: Int
    @Binding var focusedIndex: Int?
    let onActivate: (Int) -> Void
    var onQuickLook: ((Int) -> Void)?

    @FocusState private var focused: Bool
    @State private var didInitialFocus = false

    func body(content: Content) -> some View {
        content
            .focusable(count > 0)
            .focusEffectDisabled()
            .focused($focused)
            .onMoveCommand { move($0) }
            .onKeyPress(.return) { activate() }
            .onKeyPress(.space) { quickLook() }
            .onAppear { autoFocusIfNeeded() }
            .onChange(of: count) { autoFocusIfNeeded() }
    }

    /// Grab focus once, when the first items arrive, so the arrows work without
    /// a click. Guarded so later page-loads (which grow `count`) don't yank
    /// focus back mid-scroll.
    private func autoFocusIfNeeded() {
        guard !didInitialFocus, count > 0 else { return }
        didInitialFocus = true
        if focusedIndex == nil { focusedIndex = 0 }
        focused = true
    }

    private func move(_ direction: MoveCommandDirection) {
        guard count > 0 else { return }
        let current = focusedIndex ?? 0
        let step: Int
        switch direction {
        case .left: step = -1
        case .right: step = 1
        case .up: step = -max(1, columns)
        case .down: step = max(1, columns)
        @unknown default: step = 0
        }
        let next = current + step
        if next >= 0 && next < count {
            focusedIndex = next
        } else if focusedIndex == nil {
            focusedIndex = 0
        }
    }

    private func activate() -> KeyPress.Result {
        guard let index = focusedIndex, index >= 0, index < count else { return .ignored }
        onActivate(index)
        return .handled
    }

    private func quickLook() -> KeyPress.Result {
        guard let onQuickLook, let index = focusedIndex, index >= 0, index < count else { return .ignored }
        onQuickLook(index)
        return .handled
    }
}

extension View {
    /// See `GridKeyboardNavigation`. `onQuickLook` nil ⇒ Space is left alone.
    func gridKeyboardNavigation(
        count: Int,
        columns: Int,
        focusedIndex: Binding<Int?>,
        onActivate: @escaping (Int) -> Void,
        onQuickLook: ((Int) -> Void)? = nil
    ) -> some View {
        modifier(GridKeyboardNavigation(
            count: count,
            columns: columns,
            focusedIndex: focusedIndex,
            onActivate: onActivate,
            onQuickLook: onQuickLook
        ))
    }
}
#endif
