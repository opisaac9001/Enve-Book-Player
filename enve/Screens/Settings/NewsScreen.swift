import SwiftUI
import UIKit

struct NewsScreen: View {
    @Environment(\.hearth) private var hearth

    private struct NewsItem: Identifiable {
        let id: String
        let title: String
        let body: String
        let linkTitle: String
        let url: URL?
    }

    private static let items = [
        NewsItem(
            id: "discord-launch-1",
            title: "Enve is on Discord",
            body: "There's finally a Discord server. It's the best place to report issues, share feedback, and hear what's coming next.",
            linkTitle: "Join the Discord",
            url: URL(string: "https://discord.gg/nXtASwRkQy")
        )
    ]

    private static let dismissedKey = "enve.dismissedAnnouncementId"

    static var shouldAutoPresent: Bool {
        guard let latest = items.first else { return false }
        return UserDefaults.standard.string(forKey: dismissedKey) != latest.id
    }

    static func markPresented() {
        guard let latest = items.first else { return }
        UserDefaults.standard.set(latest.id, forKey: dismissedKey)
    }

    var body: some View {
        SettingsScaffold(
            overline: "About",
            title: "News",
            subtitle: "Notes from the developer."
        ) {
            if Self.items.isEmpty {
                SourcesCard {
                    Text("Nothing new tonight.")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                }
            } else {
                ForEach(Self.items) { item in
                    SourcesCard {
                        Text(item.title)
                            .font(.hearthDisplay(20))
                            .foregroundStyle(hearth.text)
                        Text(item.body)
                            .font(.hearthBody)
                            .foregroundStyle(hearth.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let url = item.url {
                            EmberButton(title: item.linkTitle, systemImage: "arrow.up.forward", tint: nil) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { Self.markPresented() }
    }
}
