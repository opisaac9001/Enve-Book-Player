import SwiftUI

struct CoverView: View {
    let stableId: String
    var size: CGFloat = 40

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.15)
                        .fill(WatchTheme.emberDim)
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(WatchTheme.ember)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.15))
        .task(id: stableId) {
            image = WatchCoverStore.shared.cachedImage(for: stableId)
            if image == nil {
                image = await WatchCoverStore.shared.image(for: stableId)
            }
        }
    }
}
