import SwiftUI

/// Toolbar `Menu` for selecting a `LibrarySort`. Mirrors `CollectionSortMenu`
/// case-for-case so the affordance feels the same across the two screens.
struct LibrarySortMenu: View {
    @Binding var selectedSort: LibrarySort
    /// Whether to offer Collapse All / Expand All. Callers pass `false` when
    /// the grid isn't sectioned (a date sort, or an empty library), so the
    /// actions never appear with nothing to fold.
    var showsGroupActions: Bool = false
    var onCollapseAll: () -> Void = {}
    var onExpandAll: () -> Void = {}

    var body: some View {
        Menu {
            // Inline Picker gives the native selected-item checkmark for free.
            Picker("Sort", selection: $selectedSort) {
                ForEach(LibrarySort.allCases) { sort in
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
