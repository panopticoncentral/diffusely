import SwiftUI

/// Toolbar `Menu` for selecting a `LibrarySort`. Mirrors `CollectionSortMenu`
/// case-for-case so the affordance feels the same across the two screens.
struct LibrarySortMenu: View {
    @Binding var selectedSort: LibrarySort

    var body: some View {
        Menu {
            ForEach(LibrarySort.allCases) { sort in
                Button {
                    selectedSort = sort
                } label: {
                    HStack {
                        Text(sort.displayName)
                        Spacer()
                        if sort == selectedSort {
                            Image(systemName: "checkmark")
                        } else {
                            Image(systemName: sort.icon)
                        }
                    }
                }
            }
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
