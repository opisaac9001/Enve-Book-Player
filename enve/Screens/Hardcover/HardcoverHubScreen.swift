import SwiftUI

struct HardcoverHubScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var username: String?
    @State private var goal: HardcoverReadingGoalLegacy?
    @State private var feed: [HardcoverFeedActivity] = []
    @State private var lists: [HardcoverUserList] = []
    @State private var connectionError: String?
    @State private var loaded = false

    private var isConnected: Bool { SettingsManager.shared.hardcoverApiKey != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HardcoverScreenHeader(
                    overline: "Your reading circle",
                    title: "Hardcover",
                    line: username.map { "@\($0)" }
                )

                if !isConnected {
                    invitation
                } else {
                    if let connectionError {
                        errorLine(connectionError)
                    }

                    if !loaded {
                        HardcoverLoading(line: "Calling on Hardcover.")
                    } else {
                        if let goal {
                            goalCard(goal)
                        }
                        circleSection
                        if !lists.isEmpty {
                            listsSection
                        }
                        doorways
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbar(.hidden, for: .navigationBar)
        .task { await hardcoverLoadHub() }
        .refreshable { await hardcoverLoadHub() }
    }

    private var invitation: some View {
        VStack(spacing: 24) {
            ZStack {
                EmberGlow(tint: hearth.ember, isBreathing: true, intensity: 0.5)
                    .frame(height: 160)
                Image(systemName: "book.closed.fill")
                    .font(.hearthUI(40))
                    .foregroundStyle(hearth.ember)
            }

            VStack(spacing: 10) {
                Text("Reading is better in company.")
                    .font(.hearthDisplay(24, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .multilineTextAlignment(.center)
                Text(
                    "Hardcover keeps your goals, your lists, and your friends' evenings. Connect it once and your finished books find their way there."
                )
                .font(.hearthBody)
                .foregroundStyle(hearth.textSecondary)
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)

            NavigationLink {
                HardcoverScreen()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.hearthUI(15, weight: .semibold))
                    Text("Connect Hardcover")
                        .font(.hearthUI(16, weight: .semibold))
                }
                .foregroundStyle(hearth.onEmber)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(hearth.ember, in: Capsule())
            }
            .buttonStyle(PressableStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 24)
    }

    private func errorLine(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.hearthUI(12))
            Text(message)
                .font(.hearthCaption)
        }
        .foregroundStyle(hearth.statusWarn)
        .padding(.horizontal, 24)
    }

    private func goalCard(_ goal: HardcoverReadingGoalLegacy) -> some View {
        NavigationLink {
            HardcoverGoalScreen()
        } label: {
            HardcoverCard {
                HStack(alignment: .firstTextBaseline) {
                    Overline("\(goal.year) reading goal")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.hearthUI(11, weight: .semibold))
                        .foregroundStyle(hearth.textTertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(goal.current)")
                        .font(.hearthDisplay(36))
                        .foregroundStyle(hearth.text)
                    Text("of \(goal.target) books")
                        .font(.hearthUI(15))
                        .foregroundStyle(hearth.textSecondary)
                }
                Ribbon(progress: goal.progress, tint: hearth.ember)
                Text(hardcoverGoalLine(goal))
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
            }
        }
        .buttonStyle(PressableStyle())
        .padding(.horizontal, 24)
    }

    private func hardcoverGoalLine(_ goal: HardcoverReadingGoalLegacy) -> String {
        let remaining = goal.target - goal.current
        if remaining <= 0 { return "Done, with the year still going." }
        return remaining == 1 ? "One book to go." : "\(remaining) books to go."
    }

    private var circleSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Overline("The circle")
                Spacer()
                NavigationLink {
                    HardcoverActivityScreen()
                } label: {
                    Text("See all")
                        .font(.hearthUI(13, weight: .medium))
                        .foregroundStyle(hearth.ember)
                }
            }
            .padding(.horizontal, 24)

            if feed.isEmpty {
                Text("Your circle is quiet for now. Follow readers on Hardcover and their evenings appear here.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .padding(.horizontal, 24)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(feed.prefix(3)) { activity in
                        HardcoverActivityRow(activity: activity)
                        if activity.id != feed.prefix(3).last?.id {
                            Rectangle().fill(hearth.hairline).frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private var listsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Overline("Your lists")
                Spacer()
                NavigationLink {
                    HardcoverListsScreen()
                } label: {
                    Text("See all")
                        .font(.hearthUI(13, weight: .medium))
                        .foregroundStyle(hearth.ember)
                }
            }
            .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(lists.prefix(3)) { list in
                    NavigationLink {
                        HardcoverListBooksScreen(list: list)
                    } label: {
                        HardcoverListRow(list: list)
                    }
                    .buttonStyle(PressableStyle())
                    if list.id != lists.prefix(3).last?.id {
                        Rectangle().fill(hearth.hairline).frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private var doorways: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Rooms")
            VStack(spacing: 1) {
                hardcoverDoorway(glyph: "books.vertical", title: "Your shelf there", line: "Reading, wanting, finished") {
                    HardcoverShelfScreen()
                }
                hardcoverDoorway(glyph: "chart.line.uptrend.xyaxis", title: "Trending", line: "What readers are picking up") {
                    HardcoverTrendingScreen()
                }
                hardcoverDoorway(glyph: "magnifyingglass", title: "Search", line: "Books and readers on Hardcover") {
                    HardcoverSearchScreen()
                }
                hardcoverDoorway(glyph: "person.2", title: "Friends", line: "Following and followers") {
                    HardcoverFriendsScreen()
                }
                hardcoverDoorway(glyph: "clock", title: "History", line: "Everything you finished") {
                    HardcoverHistoryScreen()
                }
                hardcoverDoorway(glyph: "link", title: "Linked books", line: "Pairs that share their progress") {
                    HardcoverLinkScreen()
                }
                hardcoverDoorway(glyph: "person.circle", title: "Profile", line: "Your page and your numbers") {
                    HardcoverProfileScreen()
                }
                hardcoverDoorway(glyph: "key", title: "Connection", line: "Disconnect or update your API key") {
                    HardcoverScreen()
                }
            }
            .background {
                RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                    .fill(hearth.bgElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous))
            .padding(.horizontal, 24)
        }
    }

    private func hardcoverDoorway<Destination: View>(
        glyph: String,
        title: String,
        line: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: glyph)
                    .font(.hearthUI(16, weight: .medium))
                    .foregroundStyle(hearth.ember)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                    Text(line)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.hearthUI(11, weight: .semibold))
                    .foregroundStyle(hearth.textTertiary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func hardcoverLoadHub() async {
        guard isConnected else { return }
        connectionError = nil

        do {
            username = try await HardcoverService.shared.getCurrentUser().username
        } catch {
            connectionError = error.localizedDescription
        }

        async let goalReq = try? HardcoverService.shared.getReadingGoal()
        async let feedReq = try? HardcoverService.shared.getActivityFeed(limit: 10)
        async let listsReq = try? HardcoverService.shared.getUserLists()
        let (g, f, l) = await (goalReq, feedReq, listsReq)
        if let g { goal = g }
        feed = f ?? []
        lists = l ?? []
        loaded = true
    }
}

struct HardcoverListRow: View {
    let list: HardcoverUserList

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: list.isPublic ? "globe" : "lock")
                .font(.hearthUI(15, weight: .medium))
                .foregroundStyle(hearth.ember)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(list.name)
                    .font(.hearthDisplay(16, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
                if let description = list.description, !description.isEmpty {
                    Text(description)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                        .lineLimit(1)
                }
                Text(hardcoverCountLine)
                    .font(.hearthUI(11))
                    .foregroundStyle(hearth.textTertiary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.hearthUI(11, weight: .semibold))
                .foregroundStyle(hearth.textTertiary)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var hardcoverCountLine: String {
        let count = list.booksCount == 1 ? "1 book" : "\(list.booksCount) books"
        return "\(count) · \(list.isPublic ? "Public" : "Private")"
    }
}
