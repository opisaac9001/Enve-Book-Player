#if os(iOS)
import SwiftUI

struct ClubThreadScreen: View {
    let store: ClubsStore
    let session: ProfileSession
    let account: ClubAccount
    let club: ClubDetails
    let read: ClubRead
    let checkpoint: ClubCheckpoint?
    let book: Book?
    let focusPostID: String?
    let closeClubs: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var revealed: Bool
    @State private var loaded = false
    @State private var posts: [ClubPost] = []
    @State private var revealedPosts: [String: ClubPost] = [:]
    @State private var revealingPosts: Set<String> = []
    @State private var loadedPages = 1
    @State private var activeLoadID: UUID?
    @State private var cursor: String?
    @State private var archived = false
    @State private var discussionTools = false
    @State private var prompt: ClubDiscussionPrompt?
    @State private var sheet: Sheet?
    @State private var removing: Removal?
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?

    private enum Sheet: Identifiable {
        case compose(ClubPost?)
        case report(ClubPost)
        case prompt

        var id: String {
            switch self {
            case .compose(let parent): "compose-" + (parent?.id ?? "new")
            case .report(let post): "report-" + post.id
            case .prompt: "prompt"
            }
        }
    }

    private enum Removal: Identifiable {
        case post(ClubPost)
        case prompt

        var id: String {
            switch self {
            case .post(let post): "post-" + post.id
            case .prompt: "prompt"
            }
        }

        var title: String {
            switch self {
            case .post: "Delete this post?"
            case .prompt: "Remove the discussion prompt?"
            }
        }

        var action: String {
            switch self {
            case .post: "Delete"
            case .prompt: "Remove Prompt"
            }
        }
    }

    init(store: ClubsStore, session: ProfileSession, account: ClubAccount, club: ClubDetails, details: ClubReadDetails,
         checkpoint: ClubCheckpoint?, book: Book?, focusPostID: String? = nil, closeClubs: @escaping () -> Void) {
        self.store = store
        self.session = session
        self.account = account
        self.club = club
        self.read = details.read
        self.checkpoint = checkpoint
        self.book = book
        self.focusPostID = focusPostID
        self.closeClubs = closeClubs
        _revealed = State(initialValue: checkpoint.map { details.completed(by: account.id).contains($0.id) } ?? true)
    }

    private var base: String { "clubs/\(club.id)/reads/\(read.id)" }
    private var threadPath: String { base + "/threads/" + (checkpoint?.id ?? "general") }
    private var heading: String { checkpoint?.label ?? "General Discussion" }
    private var canPost: Bool { !archived && read.closedAt == nil }
    private var canEditPrompt: Bool { discussionTools && canPost && club.ownerID == account.id }

    var body: some View {
        ClubPage {
            ClubHeading(overline: read.title, title: heading)
            if revealed {
                discussion
            } else {
                ClubPanel {
                    Label("Spoilers ahead", systemImage: "eye.slash").font(.headline)
                    Text("Reveal the thread when you’re ready to discuss this checkpoint.").foregroundStyle(.secondary)
                    Button("Reveal Spoilers") { revealed = true }.buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("clubs-reveal-spoilers")
                }
            }
        }
        .navigationTitle(heading)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: revealed && scenePhase == .active) {
            guard revealed, scenePhase == .active else { return }
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(20))
            }
        }
        .refreshable { if revealed { await load() } }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .compose(let parent):
                ClubPostEditor(store: store, path: threadPath, parent: parent, defaultChapter: checkpoint?.label,
                               supportsSpoilers: discussionTools) {
                    Task { await load() }
                }
            case .report(let post):
                ClubTextEditor(title: "Report Post", label: "Reason", actionTitle: "Send Report") { reason in
                    try await store.change("\(base)/posts/\(post.id)/report", method: "POST", body: ["reason": reason])
                    notice = "Report sent."
                }
            case .prompt:
                ClubTextEditor(title: "Discussion Prompt", label: "Ask your club a question", actionTitle: "Save Prompt",
                               initialText: prompt?.body ?? "", maxLength: 1_000,
                               fieldID: "clubs-prompt-body", actionID: "clubs-prompt-confirm") { body in
                    guard let body = body.clubOptional else { return }
                    try await store.change(threadPath + "/prompt", body: ["body": body])
                    await load()
                }
            }
        }
        .alert(item: $removing) { removal in
            Alert(title: Text(removal.title), primaryButton: .destructive(Text(removal.action)) {
                Task { await remove(removal) }
            }, secondaryButton: .cancel())
        }
    }

    @ViewBuilder private var discussion: some View {
        if let notice { Label(notice, systemImage: "checkmark.circle").font(.callout) }
        if let error {
            ClubErrorLine(message: error)
            Button("Try Again") { Task { await load() } }
        }
        if let focusPostID, loaded, error == nil {
            if let post = posts.first(where: { $0.id == focusPostID }) {
                Text("From Club Feed").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                postCard(post)
            } else {
                Text("This post is no longer available.").foregroundStyle(.secondary)
            }
        }
        if let prompt {
            ClubPanel {
                Label("Discussion Prompt", systemImage: "pin.fill").font(.headline)
                Text(prompt.body).textSelection(.enabled)
                if canEditPrompt {
                    HStack {
                        Button("Edit Prompt", systemImage: "pencil") { sheet = .prompt }
                            .accessibilityIdentifier("clubs-edit-discussion-prompt")
                        Button("Remove Prompt", systemImage: "trash", role: .destructive) { removing = .prompt }
                            .accessibilityIdentifier("clubs-remove-discussion-prompt")
                    }
                    .buttonStyle(.bordered)
                }
            }
        } else if canEditPrompt {
            Button("Add Discussion Prompt", systemImage: "pin") { sheet = .prompt }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("clubs-add-discussion-prompt")
        }
        if canPost {
            Button("Write a Post", systemImage: "square.and.pencil") { sheet = .compose(nil) }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("clubs-write-post")
        }
        if !loaded && error == nil {
            ProgressView().accessibilityLabel("Loading posts")
        } else if posts.isEmpty && error == nil {
            Text("Start the conversation with a thought, a question, or a favorite passage.")
                .foregroundStyle(.secondary)
        }
        ForEach(posts.filter { $0.id != focusPostID }) { post in postCard(post) }
        if cursor != nil {
            Button("Load Older Posts") { Task { await loadOlder() } }.disabled(busy)
        }
    }

    private func postCard(_ post: ClubPost) -> some View {
        let concealed = post.concealed == true
        let fullPost = revealedPosts[post.id] ?? (concealed ? nil : post)
        return ClubPanel {
            HStack {
                ClubAvatar(name: post.authorName, isYou: post.authorID == account.id)
                VStack(alignment: .leading) {
                    Text(post.authorName).font(.subheadline.weight(.semibold))
                    Text(post.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    if canPost { Button("Reply", systemImage: "arrowshape.turn.up.left") { sheet = .compose(post) } }
                    if post.authorID != account.id { Button("Report Post", systemImage: "flag") { sheet = .report(post) } }
                    if post.authorID == account.id || club.ownerID == account.id {
                        Button("Delete Post", systemImage: "trash", role: .destructive) { removing = .post(post) }
                    }
                } label: { Image(systemName: "ellipsis").padding(8) }
                .accessibilityLabel("Actions for \(post.authorName)’s post")
            }
            if let parent = post.parentID {
                let author = posts.first { $0.id == parent }?.authorName
                Label(author.map { "Reply to \($0)" } ?? "Reply", systemImage: "arrowshape.turn.up.left")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if post.isSpoiler == true {
                HStack {
                    Label("Spoiler", systemImage: fullPost == nil ? "eye.slash" : "eye")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if concealed, fullPost != nil {
                        Spacer()
                        Button("Hide Post") { revealedPosts.removeValue(forKey: post.id) }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("clubs-hide-post-\(post.id)")
                    }
                }
            }
            if let fullPost {
                postContent(fullPost)
                reactions(post)
            } else {
                Button("Reveal Post", systemImage: "eye") {
                    Task { await reveal(post) }
                }
                .buttonStyle(.bordered)
                .disabled(revealingPosts.contains(post.id))
                .accessibilityIdentifier("clubs-reveal-post-\(post.id)")
            }
        }
    }

    @ViewBuilder private func postContent(_ post: ClubPost) -> some View {
        if !post.body.isEmpty { Text(post.body).textSelection(.enabled) }
        if let passage = post.passage {
            Text(passage).font(.body.italic()).textSelection(.enabled)
                .padding(.leading, 10).overlay(alignment: .leading) {
                    Rectangle().fill(Hearth.accent).frame(width: 2).accessibilityHidden(true)
                }
            if let chapter = post.passageChapter { Text(chapter).font(.caption).foregroundStyle(.secondary) }
            if let book, book.mediaType == .ebook, session.preferences.readingEnabled {
                Button("Find in My Copy", systemImage: "magnifyingglass") {
                    store.queueBook(book, passage: passage)
                    closeClubs()
                }
            } else if let book, let chapter = matchingChapter(post, book: book) {
                Button("Play This Chapter", systemImage: "play.circle") {
                    store.queueBook(book, position: chapter.start)
                    closeClubs()
                }
            }
        }
    }

    private func reactions(_ post: ClubPost) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 5) {
                ForEach(ClubReaction.choices, id: \.self) { emoji in
                    let votes = post.reactions.filter { $0.emoji == emoji }
                    let mine = votes.contains { $0.accountID == account.id }
                    Button {
                        react(post, emoji: emoji, enabled: !mine)
                    } label: {
                        Text(votes.isEmpty ? emoji : "\(emoji) \(votes.count)").font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .tint(mine ? Hearth.accent : .secondary)
                    .accessibilityLabel("\(emoji), \(votes.count) reactions")
                    .accessibilityAddTraits(mine ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func matchingChapter(_ post: ClubPost, book: Book) -> Chapter? {
        guard book.mediaType == .audiobook, let label = post.passageChapter else { return nil }
        let key = ClubsStore.chapterKey(label)
        let matches = book.chapters?.filter { ClubsStore.chapterKey($0.title) == key } ?? []
        return matches.count == 1 ? matches.first : nil
    }

    private func react(_ post: ClubPost, emoji: String, enabled: Bool) {
        Task {
            do {
                try await store.change("\(base)/posts/\(post.id)/reaction", body: ReactionInput(emoji: emoji, enabled: enabled))
                await load()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func reveal(_ post: ClubPost) async {
        guard revealingPosts.insert(post.id).inserted else { return }
        defer { revealingPosts.remove(post.id) }
        do {
            let fullPost: ClubPost = try await store.request("\(base)/posts/\(post.id)")
            guard !Task.isCancelled, fullPost.id == post.id, fullPost.concealed != true,
                  posts.contains(where: { $0.id == post.id && $0.concealed == true }) else { return }
            revealedPosts[post.id] = fullPost
            error = nil
        } catch is CancellationError {
        } catch let error as ClubsResponseError where [401, 403, 404].contains(error.status) {
            revealedPosts.removeValue(forKey: post.id)
            posts.removeAll { $0.id == post.id }
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove(_ removal: Removal) async {
        do {
            switch removal {
            case .post(let post):
                try await store.change("\(base)/posts/\(post.id)", method: "DELETE")
                revealedPosts.removeValue(forKey: post.id)
                posts.removeAll { $0.id == post.id }
            case .prompt:
                try await store.change(threadPath + "/prompt", method: "DELETE")
                prompt = nil
            }
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func load() async {
        let loadID = UUID()
        activeLoadID = loadID
        do {
            let query = focusPostID.map { [URLQueryItem(name: "focus", value: $0)] } ?? []
            let firstPage: ClubPosts = try await store.request(threadPath, query: query)
            var received = firstPage.focusedPost.map { [$0] } ?? []
            received += firstPage.posts
            var next = firstPage.before
            for _ in 1..<loadedPages {
                guard let before = next, activeLoadID == loadID else { break }
                let page: ClubPosts = try await store.request(threadPath, query: [URLQueryItem(name: "before", value: before)])
                received += page.posts
                next = page.before
            }
            try Task.checkCancellation()
            guard activeLoadID == loadID else { return }
            var ids: Set<String> = []
            posts = received.filter { ids.insert($0.id).inserted }
            let concealedIDs = Set(posts.filter { $0.concealed == true }.map(\.id))
            revealedPosts = revealedPosts.filter { concealedIDs.contains($0.key) }
            cursor = next
            archived = firstPage.archived
            discussionTools = firstPage.discussionTools == true
            prompt = firstPage.prompt
            loaded = true
            error = nil
        } catch is CancellationError {
        } catch let error as ClubsResponseError where [401, 403, 404].contains(error.status) {
            guard activeLoadID == loadID else { return }
            posts = []
            revealedPosts = [:]
            prompt = nil
            cursor = nil
            archived = true
            self.error = error.localizedDescription
        } catch {
            guard activeLoadID == loadID else { return }
            revealedPosts = [:]
            self.error = error.localizedDescription
        }
    }

    private func loadOlder() async {
        guard cursor != nil, !busy else { return }
        busy = true
        defer { busy = false }
        loadedPages += 1
        await load()
    }

    private struct ReactionInput: Encodable { let emoji: String; let enabled: Bool }
}

private struct ClubPostEditor: View {
    let store: ClubsStore
    let path: String
    let parent: ClubPost?
    let defaultChapter: String?
    let supportsSpoilers: Bool
    let onSent: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var includePassage = false
    @State private var passage = ""
    @State private var chapter = ""
    @State private var isSpoiler = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(parent.map { "Reply to \($0.authorName)" } ?? "Message") {
                    TextField("Write a thought or question", text: $message, axis: .vertical).lineLimit(3...8)
                        .accessibilityIdentifier("clubs-post-body")
                }
                Section {
                    Toggle("Share a Short Passage", isOn: $includePassage)
                    if includePassage {
                        TextField("Passage", text: $passage, axis: .vertical).lineLimit(2...5)
                        TextField("Chapter (optional)", text: $chapter)
                    }
                }
                if supportsSpoilers {
                    Section {
                        Toggle("Mark as Spoiler", isOn: parent?.isSpoiler == true ? .constant(true) : $isSpoiler)
                            .disabled(parent?.isSpoiler == true)
                            .accessibilityIdentifier("clubs-mark-post-spoiler")
                        if parent?.isSpoiler == true {
                            Text("Replies to spoiler posts are hidden too.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error { ClubErrorLine(message: error) }
            }
            .navigationTitle(parent == nil ? "New Post" : "Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") { submit() }.disabled(busy || (message.clubOptional == nil && (!includePassage || passage.clubOptional == nil)))
                        .accessibilityIdentifier("clubs-post-confirm")
                }
            }
            .onAppear { if chapter.isEmpty { chapter = defaultChapter ?? "" } }
        }
    }

    private func submit() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let input = PostInput(body: message.clubOptional, passage: includePassage ? passage.clubOptional : nil,
                                      passageChapter: includePassage ? chapter.clubOptional : nil, parentID: parent?.id,
                                      isSpoiler: supportsSpoilers ? isSpoiler || parent?.isSpoiler == true : nil)
                let _: ClubsAPI.ID = try await store.request(path, method: "POST", body: input)
                onSent()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }

    private struct PostInput: Encodable {
        let body: String?
        let passage: String?
        let passageChapter: String?
        let parentID: String?
        let isSpoiler: Bool?
    }
}

private struct ClubTextEditor: View {
    let title: String
    let label: String
    let actionTitle: String
    let maxLength: Int?
    let fieldID: String
    let actionID: String
    let submit: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var error: String?
    @State private var busy = false

    init(title: String, label: String, actionTitle: String, initialText: String = "", maxLength: Int? = nil,
         fieldID: String = "clubs-report-reason", actionID: String = "clubs-report-confirm",
         submit: @escaping (String) async throws -> Void) {
        self.title = title
        self.label = label
        self.actionTitle = actionTitle
        self.maxLength = maxLength
        self.fieldID = fieldID
        self.actionID = actionID
        self.submit = submit
        _text = State(initialValue: initialText)
    }

    private var length: Int { text.clubOptional?.precomposedStringWithCanonicalMapping.unicodeScalars.count ?? 0 }

    var body: some View {
        NavigationStack {
            Form {
                TextField(label, text: $text, axis: .vertical).lineLimit(2...6)
                    .accessibilityIdentifier(fieldID)
                if let maxLength, length > maxLength {
                    Text("Use \(maxLength) characters or fewer.").foregroundStyle(.secondary)
                }
                if let error { ClubErrorLine(message: error) }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle) {
                        busy = true
                        Task {
                            defer { busy = false }
                            do { try await submit(text); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    .disabled(busy || length == 0 || maxLength.map { length > $0 } == true)
                    .accessibilityIdentifier(actionID)
                }
            }
        }
    }
}
#endif
