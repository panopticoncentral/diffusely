import SwiftUI

struct FiltersToolbar: View {
    @Binding var selectedRating: ContentRating
    @Binding var selectedPeriod: Timeframe
    @Binding var selectedSort: ImageSort
    
    var body: some View {
        HStack(spacing: 8) {
            // Sort picker
            Menu {
                ForEach(ImageSort.allCases) { sort in
                    Button(action: {
                        selectedSort = sort
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sort.displayName)
                                    .fontWeight(.medium)
                                Text(sort.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if sort == selectedSort {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: selectedSort.icon)
                        .font(.system(size: 12, weight: .medium))
                    Text(selectedSort.shortName)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            
            // Divider
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 1, height: 18)
            
            // Period picker
            Menu {
                ForEach(Timeframe.allCases) { period in
                    Button(action: {
                        selectedPeriod = period
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(period.displayName)
                                    .fontWeight(.medium)
                                Text(period.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if period == selectedPeriod {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "calendar")
                        .font(.system(size: 12, weight: .medium))
                    Text(selectedPeriod.shortName)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            
            // Divider
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 1, height: 18)
            
            // Rating picker
            Menu {
                ForEach(ContentRating.allCases) { rating in
                    Button(action: {
                        selectedRating = rating
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rating.displayName)
                                    .fontWeight(.medium)
                                Text(rating.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if rating == selectedRating {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "eye")
                        .font(.system(size: 12, weight: .medium))
                    Text(selectedRating.displayName)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
        }
        .padding(.horizontal)
    }
}
