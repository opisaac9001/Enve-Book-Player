#if os(iOS)
import SwiftUI

struct ClubDashboard: View {
    let store: ClubsStore
    let session: ProfileSession
    let account: ClubAccount
    let clubID: String
    let closeClubs: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var club: ClubDetails?
    @State private var tab = Section.now
    @State private var invitation: ClubInvite?
    @State private var showInvite = false
    @State private var action: MemberAction?
    @State private var editor: ReadEditor?
    @State private var error: String?
    @State private var changing = false

    private enum Section: String, CaseIterable, Identifiable {
        case now = "Now Reading", activity = "Activity", next = "Next Up", history = "History"
        var id: String { rawValue }
    }

    private enum ReadEditor: Identifiable {
        case copy, details(Book?), winner(ClubNomination, String)
        var id: Int { switch self { case .copy: 0; case .details: 1; case .winner: 2 } }
    }

    private enum MemberAction: Identifiable {
        case leave, delete, revoke, handoff(ClubAccount), remove(ClubAccount), block(ClubAccount, Bool)
        var id: String { label }
        var label: String {
            switch self {
            case .leave: "Leave Club"
            case .delete: "Delete Club"
            case .revoke: "Revoke Invitation"
            case .handoff(let member): "Make \(member.name) the Host"
            case .remove(let member): "Remove \(member.name)"
            case .block(let member, let blocked): blocked ? "Unblock \(member.name)" : "Block \(member.name)"
            }
        }
    }

    private var isHost: Bool { club?.ownerID == account.id }
    private var base: String { "clubs/\(clubID)" }

    var body: some View {
        ClubPage {
            if let club {
                ClubHeading(overline: "Private book club", title: club.name)
                sections
                switch tab {
                case .now: nowReading(club)
                case .activity: activity(club)
                case .next:
                    ClubNextUpView(store: store, account: account, clubID: clubID, isHost: isHost) { nominee, pollID in
                        editor = .winner(nominee, pollID)
                    }
                case .history: history(club)
                }
            } else if error == nil {
                ProgressView().accessibilityLabel("Loading club")
            }
            if let error {
                ClubErrorLine(message: error)
                Button("Try Again") { Task { await reload() } }
            }
        }
        .navigationTitle(club?.name ?? "Club")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if club != nil {
                ToolbarItem(placement: .primaryAction) { clubMenu }
            }
        }
        .refreshable { await reload() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(25))
            }
        }
        .sheet(isPresented: $showInvite) { inviteSheet }
        .sheet(item: $editor, onDismiss: { if let book = pendingBook { pendingBook = nil; editor = .details(book) } }) { editor in
            switch editor {
            case .copy:
                ClubCopyPicker(session: session) { pendingBook = $0 }
            case .details(let book):
                ClubStartEditor(store: store, input: .next(clubID: clubID, book: book, nomination: nil, pollID: nil), onSaved: startedRead)
            case .winner(let nominee, let pollID):
                ClubStartEditor(store: store, input: .next(clubID: clubID, book: nil, nomination: nominee, pollID: pollID), onSaved: startedRead)
            }
        }
        .alert(item: $action) { action in
            Alert(title: Text(action.label + "?"), message: Text(actionDescription(action)),
                  primaryButton: .destructive(Text(action.label)) { perform(action) }, secondaryButton: .cancel())
        }
    }

    @State private var pendingBook: Book?

    private var sections: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Section.allCases) { choice in
                    HearthChip(title: choice.rawValue, isSelected: tab == choice) { tab = choice }
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Club sections")
    }

    @ViewBuilder private func nowReading(_ club: ClubDetails) -> some View {
        if let read = club.currentRead {
            ClubReadingView(store: store, session: session, account: account, club: club, read: read, closeClubs: closeClubs)
                .id(read.id)
        } else {
            ClubPanel {
                Text("Choose the first book").font(.headline)
                if isHost { startMenu }
                else { Text("The host can add a book or start a vote in Next Up.").foregroundStyle(.secondary) }
            }
        }
        ClubPanel {
            Text("Members").font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(club.members, id: \.id) { member in
                HStack {
                    ClubAvatar(name: member.name, isYou: member.id == account.id)
                    VStack(alignment: .leading) {
                        Text(member.name)
                        if member.id == club.ownerID { Text("Host").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if member.id != account.id { memberMenu(member, club: club) }
                }
            }
        }
    }

    private func activity(_ club: ClubDetails) -> some View {
        ClubPanel {
            Text("Recent Activity").font(.headline).accessibilityAddTraits(.isHeader)
            if club.activity.isEmpty { Text("Club updates will appear here.").foregroundStyle(.secondary) }
            ForEach(club.activity) { event in
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.description)
                    Text(event.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func history(_ club: ClubDetails) -> some View {
        ClubPanel {
            Text("Past Reads").font(.headline).accessibilityAddTraits(.isHeader)
            if club.history.isEmpty { Text("Finished reading plans and discussions will appear here.").foregroundStyle(.secondary) }
            ForEach(club.history) { read in
                NavigationLink {
                    ClubPage {
                        ClubReadingView(store: store, session: session, account: account, club: club, read: read, closeClubs: closeClubs)
                    }
                    .navigationTitle(read.title)
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(read.title)
                            if let closed = read.closedAt { Text(closed, style: .date).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var clubMenu: some View {
        Menu {
            if isHost {
                Button("Invite Members", systemImage: "person.badge.plus") { showInvite = true }
                startMenu
                Button("Revoke Invitation", systemImage: "link.badge.plus", role: .destructive) { action = .revoke }
                Button("Delete Club", systemImage: "trash", role: .destructive) { action = .delete }
            } else {
                Button("Leave Club", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { action = .leave }
            }
        } label: { Image(systemName: "ellipsis.circle") }
        .accessibilityLabel("Club actions")
    }

    private var startMenu: some View {
        Menu("Start a Read", systemImage: "book") {
            Button("Choose from My Library", systemImage: "books.vertical") { editor = .copy }
            Button("Enter Book Details", systemImage: "pencil") { editor = .details(nil) }
        }
    }

    private func memberMenu(_ member: ClubAccount, club: ClubDetails) -> some View {
        let blocked = club.blockedIDs.contains(member.id)
        return Menu {
            Button(blocked ? "Unblock Member" : "Block Member", systemImage: "hand.raised") { action = .block(member, blocked) }
            if isHost {
                Button("Transfer Hosting", systemImage: "person.badge.key") { action = .handoff(member) }
                Button("Remove from Club", systemImage: "person.badge.minus", role: .destructive) { action = .remove(member) }
            }
        } label: { Image(systemName: "ellipsis").padding(10) }
        .accessibilityLabel("Actions for \(member.name)")
    }

    private var inviteSheet: some View {
        NavigationStack {
            ClubPage {
                ClubHeading(overline: "Private invitation", title: "Invite Friends")
                if let invitation {
                    ClubPanel {
                        Text(invitation.displayCode).font(.title2.monospaced()).textSelection(.enabled)
                            .accessibilityIdentifier("clubs-active-invite")
                        Text("Expires \(invitation.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote).foregroundStyle(.secondary)
                        ShareLink(item: invitation.shareText) { Label("Share Invitation", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.borderedProminent)
                    }
                }
                Text("Anyone with the active invitation can join. A new code replaces the previous one.").foregroundStyle(.secondary)
                Button(invitation == nil ? "Generate Invite Code" : "Replace Invite Code") { generateInvite() }
                    .buttonStyle(.bordered).disabled(changing)
                if let error { ClubErrorLine(message: error) }
            }
            .navigationTitle("Invitation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showInvite = false } } }
        }
    }

    private func reload() async {
        do {
            club = try await store.request(base)
            error = nil
        } catch is CancellationError {
        } catch let error as ClubsResponseError where error.status == 404 {
            await store.removeLocalClub(clubID)
            club = nil
            self.error = error.localizedDescription
        } catch { self.error = error.localizedDescription }
    }

    private func generateInvite() {
        changing = true
        Task {
            defer { changing = false }
            do { invitation = try await store.request(base + "/invite", method: "POST"); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }

    private func startedRead(_ id: String) {
        editor = nil
        tab = .now
        Task { await reload() }
    }

    private func actionDescription(_ action: MemberAction) -> String {
        switch action {
        case .leave: "You’ll lose access to this club’s reading plan and discussions."
        case .delete: "The reading plan, discussions, and history will be deleted for everyone."
        case .revoke: "The current invitation will stop working."
        case .handoff: "The new host will manage invitations, the plan, and membership."
        case .remove: "This member will lose access to the club and its invitations."
        case .block(_, let blocked): blocked ? "You’ll be able to see their posts and reactions again." : "You’ll stop seeing each other’s posts and reactions."
        }
    }

    private func perform(_ action: MemberAction) {
        Task {
            do {
                switch action {
                case .leave: try await store.change(base + "/leave", method: "POST")
                case .delete: try await store.change(base, method: "DELETE")
                case .revoke:
                    try await store.change(base + "/invite", method: "DELETE")
                    invitation = nil
                case .handoff(let member): try await store.change(base + "/host", body: ["memberID": member.id])
                case .remove(let member): try await store.change(base + "/members/\(member.id)", method: "DELETE")
                case .block(let member, let blocked): try await store.change("blocks/\(member.id)", method: blocked ? "DELETE" : "PUT")
                }
                switch action {
                case .leave, .delete:
                    await store.removeLocalClub(clubID)
                    dismiss()
                default: await reload()
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct ClubAvatar: View {
    let name: String
    let isYou: Bool
    @Environment(\.hearth) private var hearth

    var body: some View {
        Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased())
            .font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            .frame(width: 30, height: 30)
            .foregroundStyle(hearth.text)
            .background(isYou ? hearth.ember.opacity(0.28) : hearth.bgElevated, in: Circle())
            .overlay(Circle().strokeBorder(isYou ? hearth.ember : hearth.hairline))
            .accessibilityHidden(true)
    }
}
#endif
