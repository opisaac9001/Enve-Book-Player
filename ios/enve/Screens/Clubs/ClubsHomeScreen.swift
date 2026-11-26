#if os(iOS)
import SwiftUI

struct ClubsHomeScreen: View {
    let store: ClubsStore
    let session: ProfileSession
    var initialCode: String? = nil
    var initialBook: Book? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var path: [Route] = []
    @State private var pendingPath: [Route]?
    @State private var destination: Destination?
    @State private var name = ""
    @State private var recoveryKey = ""
    @State private var creatingAccount = true
    @State private var busy = false
    @State private var loaded = false
    @State private var handledInitialRoute = false
    @State private var supportsFeed = false
    @State private var error: String?

    private enum Route: Hashable {
        case club(String)
        case discussion(ClubDiscussionLink)
    }

    private enum Destination: String, Identifiable {
        case create, join, account, feed
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ClubPage {
                ClubHeading(overline: "Read together", title: "Book Clubs")
                if let account = store.account {
                    signedIn(account)
                } else {
                    signIn
                }
            }
            .navigationTitle("Book Clubs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if store.account != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button { destination = .account } label: { Image(systemName: "person.crop.circle") }
                            .accessibilityLabel("Clubs account")
                    }
                }
            }
            .navigationDestination(for: Route.self) { route in
                if let account = store.account {
                    switch route {
                    case .club(let id):
                        ClubDashboard(store: store, session: session, account: account, clubID: id, closeClubs: { dismiss() })
                    case .discussion(let link):
                        ClubDiscussionLinkScreen(store: store, session: session, account: account, link: link, closeClubs: { dismiss() })
                    }
                }
            }
            .task(id: store.account?.id) {
                guard store.account != nil else { loaded = false; path = []; return }
                if !handledInitialRoute {
                    handledInitialRoute = true
                    if initialCode != nil { destination = .join }
                    else if initialBook != nil { destination = .create }
                }
                await reload()
                let discovery: Features? = try? await store.request("discovery")
                if !Task.isCancelled { supportsFeed = discovery?.features.contains("club-feed") == true }
            }
            .task(id: path.count) {
                if path.isEmpty, loaded, store.account != nil { await reload() }
            }
            .refreshable { if store.account != nil { await reload() } }
            .sheet(item: $destination, onDismiss: openPendingClub) { destination in
                switch destination {
                case .create:
                    ClubStartEditor(store: store, input: .create(initialBook), onSaved: openClub)
                case .join:
                    ClubJoinEditor(store: store, initialCode: initialCode ?? "", onJoined: openClub)
                case .account:
                    ClubAccountScreen(store: store)
                case .feed:
                    ClubActivityFeedScreen(store: store, onOpen: openFeedEvent)
                }
            }
        }
        .tint(Hearth.accent)
    }

    private func signedIn(_ account: ClubAccount) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack { clubActions }
                VStack(alignment: .leading) { clubActions }
            }
            ViewThatFits(in: .horizontal) {
                HStack { memberActions(account) }
                VStack(alignment: .leading) { memberActions(account) }
            }
            if let error { ClubErrorLine(message: error) }
            if !loaded && error == nil {
                ProgressView().accessibilityLabel("Loading clubs")
            } else if store.clubSummaries.isEmpty {
                ClubPanel {
                    Text("Your reading group starts here.").font(.headline)
                    Text("Start a private club or join friends with an invitation.").foregroundStyle(.secondary)
                }
            } else {
                ForEach(store.clubSummaries) { club in
                    NavigationLink(value: Route.club(club.id)) {
                        ClubPanel {
                            Label(club.name, systemImage: "books.vertical").font(.headline)
                            if let current = club.currentTitle { Text(current).foregroundStyle(.secondary) }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func memberActions(_ account: ClubAccount) -> some View {
        Group {
            if supportsFeed {
                Button("Club Feed", systemImage: "text.bubble") { destination = .feed }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("clubs-feed")
            }
            NavigationLink {
                ClubNotesScreen(store: store, account: account, source: .personal)
            } label: {
                Label("My Club Notes", systemImage: "note.text")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("clubs-my-notes")
        }
    }

    private struct Features: Decodable { let features: [String] }

    private var clubActions: some View {
        Group {
            Button { destination = .create } label: { Label("Start a Club", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("clubs-create")
            Button { destination = .join } label: { Label("Join a Club", systemImage: "person.badge.plus") }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("clubs-join")
        }
        .controlSize(.large)
    }

    private var signIn: some View {
        ClubPanel {
            Text(initialCode == nil ? "Read the same book with friends" : "You’re invited to an Enve book club")
                .font(.headline)
            Text("Members see your display name and what you share in the club. Use any copy of the book.")
                .foregroundStyle(.secondary)
            if let issue = store.storageError ?? error { ClubErrorLine(message: issue) }
            if creatingAccount {
                TextField("Display name", text: $name).textContentType(.nickname)
                    .accessibilityIdentifier("clubs-display-name")
            } else {
                SecureField("Recovery key", text: $recoveryKey)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
            }
            Button(creatingAccount ? "Create Clubs Profile" : "Restore Clubs Profile") {
                busy = true
                error = nil
                Task {
                    defer { busy = false }
                    do {
                        try await store.authorize(name: creatingAccount ? name : nil, recoveryKey: recoveryKey)
                        recoveryKey = ""
                    } catch { self.error = error.localizedDescription }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || (creatingAccount ? name.clubTrimmed.isEmpty : recoveryKey.clubTrimmed.isEmpty))
            Button(creatingAccount ? "I already have a profile" : "Create a new profile") {
                creatingAccount.toggle()
                error = nil
            }
            .disabled(busy)
        }
    }

    private func reload() async {
        do {
            try await store.refreshClubs()
            loaded = true
            error = nil
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }

    private func openClub(_ id: String) {
        openFeedEvent(id, discussion: nil)
    }

    private func openFeedEvent(_ id: String, discussion: ClubDiscussionLink?) {
        var routes = [Route.club(id)]
        if let discussion { routes.append(.discussion(discussion)) }
        pendingPath = routes
        destination = nil
    }

    private func openPendingClub() {
        guard let pendingPath else { return }
        self.pendingPath = nil
        path = pendingPath
        Task { await reload() }
    }
}

private struct ClubJoinEditor: View {
    let store: ClubsStore
    let initialCode: String
    let onJoined: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Invitation") {
                    TextField("Invite code", text: $code)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .accessibilityIdentifier("clubs-invite-code")
                }
                Section {
                    TextField("Display name", text: $name)
                        .textContentType(.nickname).autocorrectionDisabled()
                        .accessibilityIdentifier("clubs-join-display-name")
                } header: {
                    Text("Your Name")
                } footer: {
                    Text("Members of this club can see this name, your checkpoint check-ins, and anything you choose to share. Automatic progress is a separate choice.")
                }
                if let error { ClubErrorLine(message: error) }
            }
            .disabled(busy)
            .navigationTitle("Join a Club")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join", action: join)
                        .disabled(code.clubTrimmed.isEmpty || name.clubTrimmed.isEmpty || busy)
                        .accessibilityIdentifier("clubs-join-confirm")
                }
            }
            .onAppear {
                if code.isEmpty { code = initialCode }
                if name.isEmpty { name = store.account?.name ?? "" }
            }
            .interactiveDismissDisabled(busy)
        }
    }

    private func join() {
        busy = true
        error = nil
        var body = ["code": code]
        if name.clubTrimmed != store.account?.name { body["name"] = name.clubTrimmed }
        Task {
            defer { busy = false }
            do {
                let id: ClubsAPI.ID = try await store.request("clubs/join", method: "POST", body: body)
                onJoined(id.id)
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct ClubAccountScreen: View {
    let store: ClubsStore
    @Environment(\.dismiss) private var dismiss
    @State private var showRecovery = false
    @State private var confirmation: AccountAction?
    @State private var busy = false
    @State private var error: String?

    private enum AccountAction: String, Identifiable {
        case regenerate = "Replace Recovery Key", signOut = "Sign Out", delete = "Delete Clubs Profile"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    Text(store.account?.name ?? "Clubs")
                    Button(showRecovery ? "Hide Recovery Key" : "Show Recovery Key") { showRecovery.toggle() }
                    if showRecovery, let key = store.recoveryKey {
                        Text(key).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Text("Save this key somewhere private. It restores your club membership on another device.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Replace Recovery Key") { confirmation = .regenerate }
                }
                Section {
                    Button("Sign Out") { confirmation = .signOut }
                    Button("Delete Clubs Profile", role: .destructive) { confirmation = .delete }
                    if let error { ClubErrorLine(message: error) }
                }
                Section("Support") {
                    Link("Enve support", destination: URL(string: "https://envemedia.com/community.html")!)
                }
            }
            .disabled(busy)
            .navigationTitle("Clubs Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert(item: $confirmation) { action in
                Alert(title: Text(action.rawValue), message: Text(message(for: action)),
                      primaryButton: .destructive(Text(action.rawValue)) { perform(action) }, secondaryButton: .cancel())
            }
        }
    }

    private func message(for action: AccountAction) -> String {
        switch action {
        case .regenerate: "The old key will stop working and your other devices will be signed out."
        case .signOut: "Save your recovery key before signing out."
        case .delete: "Your posts, progress, and votes will be removed. Clubs with other members pass to another host."
        }
    }

    private func perform(_ action: AccountAction) {
        busy = true
        Task {
            defer { busy = false }
            do {
                if action == .regenerate { try await store.rotateRecoveryKey(); showRecovery = true }
                else { try await store.endSession(deleting: action == .delete); dismiss() }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct ClubPage<Content: View>: View {
    @Environment(\.hearth) private var hearth
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .frame(maxWidth: 680)
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(HearthBackground())
        .foregroundStyle(hearth.text)
    }
}

struct ClubHeading: View {
    let overline: String
    let title: String
    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Overline(overline)
            Text(title).font(.hearthScreenTitle).foregroundStyle(hearth.text)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

struct ClubPanel<Content: View>: View {
    @Environment(\.hearth) private var hearth
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(hearth.bgElevated, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(hearth.hairline))
    }
}

struct ClubErrorLine: View {
    var message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle").font(.callout)
            .foregroundStyle(.red)
    }
}

extension String {
    var clubTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var clubOptional: String? { clubTrimmed.isEmpty ? nil : clubTrimmed }
}
#endif
