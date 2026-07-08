import SwiftUI

/// Toolbar `Menu` for selecting a `LibrarySort`. Mirrors `CollectionSortMenu`
/// case-for-case so the affordance feels the same across the two screens.
struct LibrarySortMenu: View {
    @Binding var selectedSort: LibrarySort

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
        } label: {
            #if os(macOS)
            Label("Sort", systemImage: "arrow.up.arrow.down.circle")
            #else
            Image(systemName: "arrow.up.arrow.down.circle")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(.primary)
            #endif
        }
        .accessibilityLabel("Sort")
    }
}
