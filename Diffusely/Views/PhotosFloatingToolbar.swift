//
//  PhotosFloatingToolbar.swift
//  Diffusely
//
//  Created by Claude on 8/28/25.
//

import SwiftUI

struct PhotosFloatingToolbar: View {
    @Binding var selectedRating: ContentRating
    @Binding var selectedPeriod: MetricTimeframe
    
    var body: some View {
        HStack(spacing: 12) {
            // Period picker
            Menu {
                ForEach(MetricTimeframe.allCases) { period in
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
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.system(size: 14, weight: .medium))
                    Text(selectedPeriod.shortName)
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            
            // Divider
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 1, height: 20)
            
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
                HStack(spacing: 4) {
                    Image(systemName: "eye")
                        .font(.system(size: 14, weight: .medium))
                    Text(selectedRating.displayName)
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
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