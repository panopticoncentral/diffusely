import SwiftUI

struct ImageThumbnail: View {
    let image: CivitaiImage
    
    var body: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.1))
            .overlay {
                AsyncImage(url: URL(string: image.thumbnailURL)) { phase in
                    switch phase {
                    case .success(let loadedImage):
                        loadedImage
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure(let error):
                        Image(systemName: image.isVideo ? "video" : "photo")
                            .foregroundColor(.gray)
                            .font(.title2)
                        .onAppear {
                            print("Thumbnail failed to load. ID: \(image.id), URL: \(image.thumbnailURL), Error: \(error.localizedDescription)")
                        }
                    case .empty:
                        ProgressView()
                            .scaleEffect(0.8)
                    @unknown default:
                        Image(systemName: image.isVideo ? "video" : "photo")
                            .foregroundColor(.gray)
                    }
                }
            }
            .clipped()
    }
}
