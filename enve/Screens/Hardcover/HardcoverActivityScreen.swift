import SwiftUI

struct HardcoverActivityScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var activities: [HardcoverFeedActivity] = []
    @State private var loadError: String?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HardcoverScreenHeader(overline: "Hardcover", title: "The circle")

                if !loaded {
                    HardcoverLoading(line: "Listening for your circle.")
                } else if let loadError {
                    HardcoverEmpty(glyph: "exclamationmark.triangle", title: "Hardcover is out of reach.", line: loadError)
                } else if activities.isEmpty {
                    HardcoverEmpty(
                        glyph: "bubble.left.and.bubble.right",
                        title: "Quiet, for now.",
                        line: "Follow readers on Hardcover and their evenings appear here."
                    )
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(activities) { activity in
                            HardcoverActivityRow(activity: activity)
                            if activity.id != activities.last?.id {
                                Rectangle().fill(hearth.hairline).frame(height: 1)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbar(.hidden, for: .navigationBar)
        .task { await hardcoverLoadFeed() }
        .refreshable { await hardcoverLoadFeed() }
    }

    private func hardcoverLoadFeed() async {
        loadError = nil
        do {
            activities = try await HardcoverService.shared.getActivityFeed(limit: 50)
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
    }
}

struct HardcoverActivityRow: View {
    let activity: HardcoverFeedActivity

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HardcoverAvatar(urlString: activity.userImageURL, name: activity.username)

            VStack(alignment: .leading, spacing: 6) {
                (Text(activity.username).font(.hearthUI(14, weight: .semibold)).foregroundStyle(hearth.text)
                    + Text(" \(activity.actionText)").font(.hearthUI(14)).foregroundStyle(hearth.textSecondary))
                    .lineLimit(2)

                if let title = activity.bookTitle {
                    HStack(spacing: 10) {
                        if activity.bookImageURL != nil {
                            HardcoverCoverThumb(urlString: activity.bookImageURL, width: 34)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.hearthDisplay(15, weight: .semibold))
                                .foregroundStyle(hearth.text)
                                .lineLimit(2)
                            if let author = activity.authorName {
                                Text(author)
                                    .font(.hearthCaption)
                                    .foregroundStyle(hearth.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                if let rating = activity.rating, rating > 0 {
                    HardcoverStars(rating: rating)
                }

                Text(activity.timeAgo)
                    .font(.hearthUI(11))
                    .foregroundStyle(hearth.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }
}
