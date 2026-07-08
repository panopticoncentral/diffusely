import SwiftUI

struct FeedFilterMenu: View {
    @Binding var selectedPeriod: Timeframe
    @Binding var selectedSort: FeedSort

    var body: some View {
        Menu {
            // Inline Pickers render the platform-native selected-item checkmark
            // (a hand-rolled `Button` + trailing `Image("checkmark")` doesn't, and
            // menus ignore the `Spacer()` that was meant to right-align it).
            Picker("Time", selection: $selectedPeriod) {
                ForEach(Timeframe.allCases) { period in
                    Text(period.displayName).tag(period)
                }
            }
            .pickerStyle(.inline)

            Picker("Sort", selection: $selectedSort) {
                ForEach(FeedSort.allCases) { sort in
                    Label(sort.displayName, systemImage: sort.icon).tag(sort)
                }
            }
            .pickerStyle(.inline)
        } label: {
            #if os(macOS)
            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
            #else
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(.primary)
            #endif
        }
        .accessibilityLabel("Filter")
        #if os(iOS)
        .frame(width: 44, height: 44)
        .padding(.trailing, 16)
        .padding(.top, 8)
        #endif
    }
}
