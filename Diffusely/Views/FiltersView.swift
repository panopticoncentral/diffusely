import SwiftUI

struct FiltersSheet: View {
    @Binding var selectedRating: ContentRating
    @Binding var selectedPeriod: Timeframe
    @Binding var selectedSort: ImageSort
    @Binding var isPresented: Bool

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // Content Rating
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Content Rating")
                            .font(.headline)
                            .foregroundColor(.primary)

                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 12) {
                            ForEach(ContentRating.allCases) { rating in
                                FilterOptionCard(
                                    title: rating.displayName,
                                    description: rating.description,
                                    isSelected: rating == selectedRating
                                ) {
                                    selectedRating = rating
                                }
                            }
                        }
                    }

                    // Time Period
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Time Period")
                            .font(.headline)
                            .foregroundColor(.primary)

                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 12) {
                            ForEach(Timeframe.allCases) { period in
                                FilterOptionCard(
                                    title: period.displayName,
                                    description: period.description,
                                    isSelected: period == selectedPeriod
                                ) {
                                    selectedPeriod = period
                                }
                            }
                        }
                    }

                    // Sort Order
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Sort Order")
                            .font(.headline)
                            .foregroundColor(.primary)

                        LazyVGrid(columns: [
                            GridItem(.flexible())
                        ], spacing: 12) {
                            ForEach(ImageSort.allCases) { sort in
                                FilterOptionCard(
                                    title: sort.displayName,
                                    description: sort.description,
                                    icon: sort.icon,
                                    isSelected: sort == selectedSort
                                ) {
                                    selectedSort = sort
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        isPresented = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct FilterOptionCard: View {
    let title: String
    let description: String
    let icon: String?
    let isSelected: Bool
    let action: () -> Void

    init(title: String, description: String, icon: String? = nil, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.description = description
        self.icon = icon
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if let icon = icon {
                        Image(systemName: icon)
                            .foregroundColor(.blue)
                            .frame(width: 16)
                    }
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.blue)
                    }
                }
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.blue.opacity(0.1) : Color(.secondarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    FiltersSheet(
        selectedRating: .constant(.g),
        selectedPeriod: .constant(.week),
        selectedSort: .constant(.mostReactions),
        isPresented: .constant(true)
    )
}