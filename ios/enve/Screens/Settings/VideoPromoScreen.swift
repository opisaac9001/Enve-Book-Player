import SwiftUI

struct VideoPromoScreen: View {
    @Environment(\.hearth) private var hearth

    private let testFlightURL = URL(string: "https://testflight.apple.com/join/sRmVmrT4")!

    var body: some View {
        SettingsScaffold(
            overline: "Sources & servers",
            title: "Video player",
            subtitle: "Enve's video player lives in its own app now."
        ) {
            SourcesCard {
                HStack(spacing: 14) {
                    Image(systemName: "play.tv")
                        .font(.hearthUI(24))
                        .foregroundStyle(hearth.ember)
                        .frame(width: 52, height: 52)
                        .background {
                            Circle().fill(hearth.emberSoft)
                        }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Same spirit, bigger screen")
                            .font(.hearthBody.weight(.medium))
                            .foregroundStyle(hearth.text)
                        Text("Plex, Jellyfin, Emby, and more. It's free as well.")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }
                }
                Link(destination: testFlightURL) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.hearthUI(15, weight: .semibold))
                        Text("Join the TestFlight")
                            .font(.hearthUI(16, weight: .semibold))
                    }
                    .foregroundStyle(hearth.onEmber)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(hearth.ember, in: Capsule())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Join the Enve Video Player TestFlight")
            }
        }
    }
}
