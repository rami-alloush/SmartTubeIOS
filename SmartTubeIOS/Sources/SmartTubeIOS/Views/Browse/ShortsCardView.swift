import SwiftUI
import SmartTubeIOSCore

// MARK: - ShortsCardView
//
// Portrait (9:16) card for a single YouTube Short.
// Shows the thumbnail cropped to portrait with a dark gradient overlay
// and the title text at the bottom.  Used inside ShortsRowSection.

struct ShortsCardView: View {
    let video: Video
    let onTap: () -> Void

    var body: some View {
        let url = video.thumbnailURL ?? video.highQualityThumbnailURL
        ZStack(alignment: .bottom) {
            // Portrait thumbnail — scaledToFill so landscape thumbs fill the frame.
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                case .failure:
                    Rectangle().fill(Color.secondary.opacity(0.2))
                default:
                    Rectangle().fill(Color.secondary.opacity(0.2))
                        .overlay { ProgressView() }
                }
            }
            .clipped()

            // Dark gradient + title overlay at the bottom.
            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .center,
                endPoint: .bottom
            )
            .overlay(alignment: .bottomLeading) {
                Text(video.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomTrailing) {
            let dur = video.formattedDuration
            if !dur.isEmpty {
                Text(dur)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.75))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
