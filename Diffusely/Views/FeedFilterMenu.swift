import SwiftUI

struct FeedFilterMenu: View {
    @Binding var selectedRating: ContentRating
    @Binding var selectedPeriod: Timeframe
    @Binding var selectedSort: FeedSort

    var body: some View {
        Menu {
            Menu("Content") {
                ForEach(ContentRating.allCases) { rating in
                    Button {
                        selectedRating = rating
                    } label: {
                        HStack {
                            Text(rating.displayName)
                            if rating == selectedRating {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Menu("Time") {
                ForEach(Timeframe.allCases) { period in
                    Button {
                        selectedPeriod = period
                    } label: {
                        HStack {
                            Text(period.displayName)
                            if period == selectedPeriod {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Menu("Sort") {
                ForEach(FeedSort.allCases) { sort in
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
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(.primary)
        }
        .frame(width: 44, height: 44)
        .padding(.trailing, 16)
        .padding(.top, 8)
    }
}
