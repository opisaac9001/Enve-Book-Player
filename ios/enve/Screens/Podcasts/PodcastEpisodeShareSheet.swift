#if os(iOS)
import SwiftUI
import UIKit

struct PodcastEpisodeShareSheet: View {
    let title: String
    let url: URL

    @Environment(\.hearth) private var hearth
    @State private var code: UIImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Overline("Share episode")
                Text(title)
                    .font(.hearthDisplay(24, weight: .semibold))
                    .foregroundStyle(hearth.text)

                if let code {
                    Image(uiImage: code)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 300)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Episode QR code for \(title)")
                }

                Text("Send the link or scan the QR code with your camera to open the episode.")
                    .font(.hearthUI(13))
                    .foregroundStyle(hearth.textSecondary)

                ShareLink(item: url, subject: Text(title), preview: SharePreview(title)) {
                    shareLabel("Share link", icon: "link", primary: true)
                }
                .buttonStyle(PressableStyle())

                if let code {
                    ShareLink(item: Image(uiImage: code), preview: SharePreview(title, image: Image(uiImage: code))) {
                        shareLabel("Share QR image", icon: "qrcode", primary: false)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
        .task(id: url) { code = ListeningPositionQRCode.image(for: url.absoluteString) }
    }

    private func shareLabel(_ title: String, icon: String, primary: Bool) -> some View {
        let fill = primary ? hearth.ember : hearth.bgElevated
        return Label(title, systemImage: icon)
            .font(.hearthUI(15, weight: .semibold))
            .foregroundStyle(primary ? HearthPalette.readableForeground(on: hearth.ember, dark: hearth.onEmber) : hearth.text)
            .padding(.horizontal, 18)
            .frame(minHeight: 48)
            .background {
                HearthChromeBackground(shape: .capsule, fill: fill, stroke: primary ? nil : hearth.hairline, tint: fill)
            }
    }
}
#endif
