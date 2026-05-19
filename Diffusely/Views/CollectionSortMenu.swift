import SwiftUI

struct CollectionSortMenu: View {
    @Binding var selectedSort: CollectionSort

    var body: some View {
        Menu {
            ForEach(CollectionSort.allCases) { sort in
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
    }
}
