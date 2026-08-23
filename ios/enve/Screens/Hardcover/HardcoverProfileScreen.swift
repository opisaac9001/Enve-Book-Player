import SwiftUI

struct HardcoverProfileScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var profile: HardcoverUserProfile?
    @State private var stats: HardcoverUserStats?
    @State private var loadError: String?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HardcoverScreenHeader(overline: "Hardcover", title: "Profile")

                if !loaded {
                    HardcoverLoading()
                } else if let loadError {
                    HardcoverEmpty(glyph: "exclamationmark.triangle", title: "Hardcover is out of reach.", line: loadError)
                } else if let profile {
                    header(profile)
                    if let stats {
                        statsGrid(stats)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbar(.hidden, for: .navigationBar)
        .task { await hardcoverLoadProfile() }
        .refreshable { await hardcoverLoadProfile() }
    }

    private func header(_ profile: HardcoverUserProfile) -> some View {
        VStack(spacing: 16) {
            HardcoverAvatar(urlString: profile.image?.url, name: profile.username, size: 84)

            VStack(spacing: 6) {
                Text("@\(profile.username)")
                    .font(.hearthDisplay(24, weight: .semibold))
                    .foregroundStyle(hearth.text)

                if !profile.flairs.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(profile.flairs, id: \.self) { flair in
                            Text(flair.uppercased())
                                .font(.hearthUI(10, weight: .semibold))
                                .tracking(1.2)
                                .foregroundStyle(hearth.ember)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(hearth.emberSoft, in: Capsule())
                        }
                    }
                }

                if let bio = profile.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding(.top, 2)
                }
            }

            HStack(spacing: 0) {
                hardcoverNumber(profile.booksCount ?? 0, label: "Books")
                hardcoverNumber(profile.followingCount ?? 0, label: "Following")
                hardcoverNumber(profile.followersCount ?? 0, label: "Followers")
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    private func hardcoverNumber(_ value: Int, label: String) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.hearthDisplay(24))
                .foregroundStyle(hearth.text)
            Overline(label, color: hearth.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func statsGrid(_ stats: HardcoverUserStats) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "The shape of it")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                statCell(value: "\(stats.booksRead)", label: "Books read")
                statCell(value: hardcoverCompact(stats.pagesRead), label: "Pages read")
                if let average = stats.averageRating {
                    statCell(value: String(format: "%.1f", average), label: "Average rating")
                }
                if stats.hoursListened > 0 {
                    statCell(value: String(format: "%.0f", stats.hoursListened), label: "Hours listened")
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.hearthDisplay(28))
                .foregroundStyle(hearth.text)
            Overline(label, color: hearth.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                .fill(hearth.bgElevated)
                .overlay {
                    RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                }
        }
    }

    private func hardcoverCompact(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    private func hardcoverLoadProfile() async {
        loadError = nil
        do {
            profile = try await HardcoverService.shared.getUserProfile()
            stats = try? await HardcoverService.shared.getUserStats()
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
    }
}
