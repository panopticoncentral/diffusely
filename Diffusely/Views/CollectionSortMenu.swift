import SwiftUI

struct CollectionSortMenu: View {
    @Binding var selectedSort: CollectionSort

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
        } label: {
            // Hosted in a toolbar on both platforms, which sizes the label
            // natively (and scales with Dynamic Type) — matching FeedFilterMenu,
            // unlike the old fixed 24pt iOS glyph.
            Label("Sort", systemImage: "arrow.up.arrow.down.circle")
        }
        .accessibilityLabel("Sort")
    }
}
