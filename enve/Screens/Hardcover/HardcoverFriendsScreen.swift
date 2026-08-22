import SwiftUI

struct HardcoverFriendsScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var following: [HardcoverFriend] = []
    @State private var followers: [HardcoverFriend] = []
    @State private var showingFollowers = false
    @State private var loadError: String?
    @State private var loaded = false

    private var shown: [HardcoverFriend] { showingFollowers ? followers : following }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HardcoverScreenHeader(overline: "Hardcover", title: "Friends")

                HStack(spacing: 10) {
                    HearthChip(title: "Following \(following.count)", isSelected: !showingFollowers) {
                        showingFollowers = false
                    }
                    HearthChip(title: "Followers \(followers.count)", isSelected: showingFollowers) {
                        showingFollowers = true
                    }
                }
                .padding(.horizontal, 24)

                if !loaded {
                    HardcoverLoading()
                } else if let loadError {
                    HardcoverEmpty(glyph: "exclamationmark.triangle", title: "Hardcover is out of reach.", line: loadError)
                } else if shown.isEmpty {
                    HardcoverEmpty(
                        glyph: "person.2",
                        title: showingFollowers ? "No followers yet." : "Not following anyone yet.",
                        line: "Find readers worth keeping company with on Hardcover."
                    )
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { friend in
                            hardcoverFriendRow(friend)
                            if friend.id != shown.last?.id {
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
        .task { await hardcoverLoadFriends() }
        .refreshable { await hardcoverLoadFriends() }
    }

    private func hardcoverFriendRow(_ friend: HardcoverFriend) -> some View {
        HStack(spacing: 12) {
            HardcoverAvatar(urlString: friend.imageURL, name: friend.username)
            VStack(alignment: .leading, spacing: 2) {
                Text("@\(friend.username)")
                    .font(.hearthUI(15, weight: .semibold))
                    .foregroundStyle(hearth.text)
                if let flair = friend.flair, !flair.isEmpty {
                    Text(flair)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.ember)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 11)
    }

    private func hardcoverLoadFriends() async {
        loadError = nil
        do {
            async let followingReq = HardcoverService.shared.getFollowing()
            async let followersReq = HardcoverService.shared.getFollowers()
            (following, followers) = try await (followingReq, followersReq)
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
    }
}
