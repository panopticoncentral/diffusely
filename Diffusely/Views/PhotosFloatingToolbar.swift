//
//  PhotosFloatingToolbar.swift
//  Diffusely
//
//  Created by Claude on 8/28/25.
//

import SwiftUI

struct PhotosFloatingToolbar: View {
    @Binding var selectedRating: ContentRating
    
    var body: some View {
        HStack(spacing: 16) {
            // Direct rating picker
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
                HStack(spacing: 6) {
                    Image(systemName: "eye")
                        .font(.system(size: 16, weight: .medium))
                    Text(selectedRating.displayName)
                        .font(.system(size: 14, weight: .medium))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            
            // Additional toolbar buttons can be added here
            // For example: Sort, Filter, etc.
        }
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
        }
        .padding(.horizontal)
    }
}