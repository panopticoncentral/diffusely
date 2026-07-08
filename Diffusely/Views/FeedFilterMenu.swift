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
            // Both platforms host this in a toolbar now, which sizes the label
            // natively (and scales with Dynamic Type, unlike the old fixed
            // 24pt glyph the iOS in-content header used).
            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filter")
        .help("Filter and sort")
    }
}
