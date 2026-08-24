import SwiftUI

struct CollectionSortMenu: View {
    @Binding var selectedSort: CollectionSort
    /// Whether to offer Collapse All / Expand All. Mirrors `LibrarySortMenu`:
    /// callers pass `false` for the flat date sorts, which have no sections.
    var showsGroupActions: Bool = false
    var onCollapseAll: () -> Void = {}
    var onExpandAll: () -> Void = {}

    var body: some View {
        Menu {
            // Inline Picker gives the native selected-item checkmark for free.
            Picker("Sort", selection: $selectedSort) {
                ForEach(CollectionSort.allCases) { sort in
                    Label(sort.displayName, systemImage: sort.icon).tag(sort)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            if showsGroupActions {
                // Own `Section` so the menu draws a divider between choosing a
                // sort and acting on the sections that sort produced.
                Section {
                    Button(action: onCollapseAll) {
                        Label("Collapse All", systemImage: "rectangle.compress.vertical")
                    }
                    Button(action: onExpandAll) {
                        Label("Expand All", systemImage: "rectangle.expand.vertical")
                    }
                }
            }
        } label: {
            // Hosted in a toolbar on both platforms, which sizes the label
            // natively (and scales with Dynamic Type) — matching FeedFilterMenu,
            // unlike the old fixed 24pt iOS glyph.
            Label("Sort", systemImage: "arrow.up.arrow.down.circle")
        }
        .accessibilityLabel("Sort")
    }
}
