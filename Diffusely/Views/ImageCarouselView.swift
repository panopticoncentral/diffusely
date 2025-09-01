import SwiftUI

struct ImageCarouselView: View {
    let images: [CivitaiImage]
    @Binding var selectedIndex: Int
    @Binding var isPresented: Bool
    
    @State private var showingDetails = false
    @State private var detailOffset: CGFloat = 0
    @State private var dragOffset: CGFloat = 0
    
    private let detailThreshold: CGFloat = 150
    
    var currentImage: CivitaiImage? {
        guard selectedIndex < images.count else { return nil }
        return images[selectedIndex]
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Top toolbar
                HStack {
                    Button("Done") {
                        isPresented = false
                    }
                    .foregroundColor(.white)
                    
                    Spacer()
                    
                    if !showingDetails {
                        Button(action: {
                            showingDetails = true
                        }) {
                            Image(systemName: "info.circle")
                                .foregroundColor(.white)
                        }
                    }
                }
                .padding()
                .background(Color.black.opacity(showingDetails ? 0.8 : 0.0))
                
                // Image carousel
                TabView(selection: $selectedIndex) {
                    ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                        GeometryReader { geometry in
                            AsyncImage(url: URL(string: image.detailURL)) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                case .failure(_):
                                    Rectangle()
                                        .fill(Color.gray.opacity(0.3))
                                        .overlay(
                                            VStack {
                                                Image(systemName: "photo")
                                                    .font(.system(size: 50))
                                                Text("Failed to load")
                                            }
                                            .foregroundColor(.gray)
                                        )
                                case .empty:
                                    Rectangle()
                                        .fill(Color.clear)
                                        .overlay(
                                            ProgressView()
                                                .tint(.white)
                                        )
                                @unknown default:
                                    EmptyView()
                                }
                            }
                        }
                        .tag(index)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                showingDetails.toggle()
                            }
                        }
                    }
                }
                .tabViewStyle(PageTabViewStyle())
                .frame(maxHeight: .infinity)
                .offset(y: showingDetails ? -100 : 0)
            }
            
            // Slide-up detail panel
            VStack {
                Spacer()
                
                PhotosDetailPanel(
                    image: currentImage,
                    isShowing: $showingDetails,
                    offset: $detailOffset
                )
                .offset(y: showingDetails ? detailOffset + dragOffset : 400)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            dragOffset = max(0, value.translation.height)
                        }
                        .onEnded { value in
                            withAnimation(.spring()) {
                                if value.translation.height > detailThreshold {
                                    showingDetails = false
                                    detailOffset = 0
                                } else {
                                    detailOffset = 0
                                }
                                dragOffset = 0
                            }
                        }
                )
                .animation(.spring(), value: showingDetails)
            }
        }
        .statusBarHidden(!showingDetails)
    }
}

struct PhotosDetailPanel: View {
    let image: CivitaiImage?
    @Binding var isShowing: Bool
    @Binding var offset: CGFloat
    
    var body: some View {
        VStack(spacing: 0) {
            // Handle bar
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.gray)
                .frame(width: 40, height: 5)
                .padding(.top, 8)
            
            if let image = image {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // User info
                        HStack {
                            if let username = image.username {
                                VStack(alignment: .leading) {
                                    Text(username)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text(formatDate(image.createdAt))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            
                            Button(action: {
                                withAnimation(.spring()) {
                                    isShowing = false
                                }
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        // Stats
                        HStack(spacing: 20) {
                            if let likes = image.stats.likeCount {
                                Label("\(likes)", systemImage: "heart")
                            }
                            if let comments = image.stats.commentCount {
                                Label("\(comments)", systemImage: "message")
                            }
                            if let hearts = image.stats.heartCount {
                                Label("\(hearts)", systemImage: "heart.fill")
                            }
                        }
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        
                        // Generation details
                        if let meta = image.meta {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Generation Details")
                                    .font(.headline)
                                
                                if let prompt = meta.prompt {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Prompt")
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                        Text(prompt)
                                            .font(.caption)
                                    }
                                }
                                
                                LazyVGrid(columns: [
                                    GridItem(.flexible()),
                                    GridItem(.flexible())
                                ], spacing: 8) {
                                    if let model = meta.model {
                                        DetailItem(title: "Model", value: model)
                                    }
                                    if let steps = meta.steps {
                                        DetailItem(title: "Steps", value: "\(steps)")
                                    }
                                    if let sampler = meta.sampler {
                                        DetailItem(title: "Sampler", value: sampler)
                                    }
                                    if let cfgScale = meta.cfgScale {
                                        DetailItem(title: "CFG Scale", value: String(format: "%.1f", cfgScale))
                                    }
                                    if let seed = meta.seed {
                                        DetailItem(title: "Seed", value: "\(seed)")
                                    }
                                    if let size = meta.size {
                                        DetailItem(title: "Size", value: size)
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
                .frame(maxHeight: 500)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
        )
        .padding(.horizontal)
    }
    
    private func formatDate(_ dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: dateString) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            displayFormatter.timeStyle = .short
            return displayFormatter.string(from: date)
        }
        return dateString
    }
}

struct DetailItem: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
        }
    }
}
