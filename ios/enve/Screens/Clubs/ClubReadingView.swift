#if os(iOS)
import SwiftUI

struct ClubReadingView: View {
    let store: ClubsStore
    let session: ProfileSession
    let account: ClubAccount
    let club: ClubDetails
    let read: ClubRead
    let closeClubs: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var details: ClubReadDetails?
    @State private var sheet: Sheet?
    @State private var confirmation: Confirmation?
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var downloadedBook: Book?
    @State private var copyDownloadTask: Task<Void, Never>?
    @State private var copyDownloadProgress: ClubHostedCopyDownloadProgress?
    @State private var copyDownloadError: String?

    private enum Sheet: Identifiable {
        case copy, checkpoint(ClubCheckpoint?)
        var id: String { switch self { case .copy: "copy"; case .checkpoint(let checkpoint): checkpoint?.id ?? "checkpoint" } }
    }
    private enum Confirmation: Identifiable {
        case sharing, unlink, complete(ClubCheckpoint)
        var id: String { switch self { case .sharing: "sharing"; case .unlink: "unlink"; case .complete(let checkpoint): checkpoint.id } }
    }

    private var base: String { "clubs/\(club.id)/reads/\(read.id)" }
    private var isArchived: Bool { read.closedAt != nil || details?.read.closedAt != nil }
    private var isHost: Bool { club.ownerID == account.id }
    private var localBook: Book? {
        guard let bookID = store.copy(for: read.id)?.bookID else { return nil }
        return session.appState.bookInMemory(uniqueId: bookID) ?? (downloadedBook?.uniqueId == bookID ? downloadedBook : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ClubPanel {
                Overline(isArchived ? "Past read" : "Now reading")
                Text(read.title).font(.hearthDisplay(30)).accessibilityAddTraits(.isHeader)
                if let author = read.author { Text(author).foregroundStyle(.secondary) }
                if let details { readActions(details) }
            }
            if let notice { Label(notice, systemImage: "checkmark.circle.fill").font(.callout) }
            if let details {
                ClubTrack(club: club, details: details, account: account)
                checkpoints(details)
            } else if error == nil {
                ProgressView().accessibilityLabel("Loading reading plan")
            }
            if let error {
                ClubErrorLine(message: error)
                Button("Refresh Reading Plan") { Task { await reload() } }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await reload()
                if isArchived { break }
                try? await Task.sleep(for: .seconds(25))
            }
        }
        .onDisappear { copyDownloadTask?.cancel() }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .copy:
                if let details {
                    ClubCopyPicker(session: session, read: read) { selectCopy($0, details: details) }
                }
            case .checkpoint(let checkpoint):
                ClubCheckpointEditor(store: store, clubID: club.id, readID: read.id, checkpoint: checkpoint) { Task { await reload() } }
            }
        }
        .confirmationDialog("Confirm", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
                            presenting: confirmation) { confirmation in
            switch confirmation {
            case .sharing:
                Button("Share Progress") { setSharing(true, presence: false) }
            case .unlink:
                Button("Unlink Copy", role: .destructive) { run { try await store.unlink(clubID: club.id, readID: read.id) } }
            case .complete(let checkpoint):
                Button("Confirm Check-in") { complete(checkpoint) }
                    .accessibilityIdentifier("clubs-confirm-check-in")
            }
        } message: { confirmation in
            switch confirmation {
            case .sharing:
                Text("Members can see your approximate place in this book and any completed checkpoints. You can turn off automatic sharing at any time.")
            case .unlink:
                Text("Your shared position will be removed. Checkpoints you’ve completed stay visible to the club.")
            case .complete(let checkpoint):
                Text("Everyone can see that you reached \(checkpoint.label). This also completes earlier checkpoints.")
            }
        }
    }

    @ViewBuilder private func readActions(_ details: ClubReadDetails) -> some View {
        if let book = localBook {
            Button(book.mediaType == .audiobook ? "Continue Listening" : "Continue Reading",
                   systemImage: book.mediaType == .audiobook ? "headphones" : "book") {
                store.queueBook(book)
                closeClubs()
            }
            .buttonStyle(.borderedProminent)
            if !isArchived {
                Menu("My Copy", systemImage: "book.closed") {
                    Button("Choose a Different Copy") { sheet = .copy }
                    Button("Unlink Copy", role: .destructive) { confirmation = .unlink }
                }
                .disabled(copyDownloadTask != nil)
            }
        } else if !isArchived {
            Button("Choose My Copy", systemImage: "books.vertical") { sheet = .copy }.buttonStyle(.bordered)
                .disabled(copyDownloadTask != nil)
            Text("Reading elsewhere? Check in at any checkpoint.").font(.footnote).foregroundStyle(.secondary)
        }
        if details.hostedCopy != nil || copyDownloadProgress != nil || copyDownloadError != nil {
            hostedCopyActions(details)
        }
        if !isArchived, localBook != nil {
            let sharing = details.sharing?.epoch != nil
            Toggle("Share my progress", isOn: Binding(get: { sharing }, set: { enabled in
                if enabled { confirmation = .sharing }
                else { setSharing(false, presence: false) }
            }))
            .disabled(busy)
            if sharing {
                Toggle("Show when I’m reading", isOn: Binding(get: { details.sharing?.presence == true }, set: { setSharing(true, presence: $0) }))
                    .disabled(busy)
            }
        }
        if !isArchived, details.checkpoints.contains(where: { $0.dueAt != nil }) {
            Toggle("Checkpoint reminders", isOn: Binding(get: { store.remindersEnabled(clubID: club.id) }, set: { enabled in
                run { try await store.setReminders(enabled, clubID: club.id, read: details) }
            }))
            .disabled(busy)
        }
    }

    @ViewBuilder private func hostedCopyActions(_ details: ClubReadDetails) -> some View {
        switch copyDownloadProgress {
        case .downloading(let completed, let total):
            if total == 1 {
                ProgressView("Downloading Club Copy")
            } else {
                ProgressView(value: Double(completed), total: Double(total)) {
                    Text("Downloading Club Copy")
                } currentValueLabel: {
                    Text("\(completed) of \(total) files")
                }
            }
            Button("Cancel Download", role: .cancel) { copyDownloadTask?.cancel() }
        case .importing:
            ProgressView("Adding Club Copy to Your Library")
        case nil:
            if let hostedCopy = details.hostedCopy {
                Button("Download Club Copy", systemImage: "arrow.down.circle") { download(hostedCopy, details: details) }
                    .buttonStyle(.bordered)
                    .disabled(busy || copyDownloadTask != nil)
                    .accessibilityIdentifier("clubs-download-copy")
            }
        }
        if let copyDownloadError { ClubErrorLine(message: copyDownloadError) }
    }

    private func download(_ hostedCopy: ClubHostedCopy, details: ClubReadDetails) {
        guard copyDownloadTask == nil, !busy else { return }
        copyDownloadError = nil
        copyDownloadTask = Task {
            defer {
                copyDownloadTask = nil
                copyDownloadProgress = nil
            }
            do {
                downloadedBook = try await store.downloadHostedCopy(hostedCopy, clubID: club.id, read: details, session: session) {
                    copyDownloadProgress = $0
                }
                notice = "Club copy added to your library"
                await reload()
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch { copyDownloadError = error.localizedDescription }
        }
    }

    private func checkpoints(_ details: ClubReadDetails) -> some View {
        let finished = details.completed(by: account.id)
        let next = details.checkpoints.first { !finished.contains($0.id) }
        return ClubPanel {
            Text("Reading Plan").font(.headline).accessibilityAddTraits(.isHeader)
            if let next, !isArchived {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Up next: \(next.label)").font(.subheadline.weight(.semibold))
                    if let due = next.dueAt { Text(due, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) }
                }
            }
            NavigationLink {
                thread(details: details, checkpoint: nil)
            } label: {
                Label("General Discussion", systemImage: "bubble.left.and.bubble.right")
            }
            NavigationLink {
                ClubNotesScreen(store: store, account: account,
                                source: .reading(clubID: club.id, read: read, checkpoints: details.checkpoints))
            } label: {
                Label("Reading Notes", systemImage: "note.text")
            }
            .accessibilityIdentifier("clubs-reading-notes")
            ForEach(details.checkpoints) { checkpoint in
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(checkpoint.label, systemImage: finished.contains(checkpoint.id) ? "checkmark.circle.fill" : "flag")
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 4)
                        if isHost, !isArchived {
                            Button { sheet = .checkpoint(checkpoint) } label: { Image(systemName: "pencil").padding(7) }
                                .accessibilityLabel("Edit \(checkpoint.label)")
                        }
                    }
                    if let due = checkpoint.dueAt {
                        Text(due, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { checkpointActions(checkpoint, details: details, done: finished.contains(checkpoint.id)) }
                        VStack(alignment: .leading) { checkpointActions(checkpoint, details: details, done: finished.contains(checkpoint.id)) }
                    }
                }
            }
            if isHost, !isArchived {
                Button("Add Checkpoint", systemImage: "plus") { sheet = .checkpoint(nil) }
                    .disabled(details.checkpoints.count >= 24)
            }
        }
    }

    @ViewBuilder private func checkpointActions(_ checkpoint: ClubCheckpoint, details: ClubReadDetails, done: Bool) -> some View {
        NavigationLink {
            thread(details: details, checkpoint: checkpoint)
        } label: {
            Label("Discuss", systemImage: done ? "bubble.left" : "eye.slash")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Discuss \(checkpoint.label)")
        if !done, !isArchived {
            Button("Mark Complete") { confirmation = .complete(checkpoint) }
                .buttonStyle(.bordered)
                .disabled(busy)
                .accessibilityLabel("Mark \(checkpoint.label) complete")
        }
    }

    private func thread(details: ClubReadDetails, checkpoint: ClubCheckpoint?) -> some View {
        ClubThreadScreen(store: store, session: session, account: account, club: club, details: details,
                         checkpoint: checkpoint, book: localBook, closeClubs: closeClubs)
    }

    private func selectCopy(_ book: Book, details: ClubReadDetails) {
        run {
            if let existing = store.copy(for: read.id), existing.bookID != book.uniqueId, details.sharing?.epoch != nil {
                try await store.setSharing(clubID: club.id, readID: read.id, enabled: false, presence: false)
            }
            let fresh: ClubReadDetails = try await store.request(base)
            store.link(book, clubID: club.id, read: fresh)
        }
    }

    private func setSharing(_ enabled: Bool, presence: Bool) {
        run {
            try await store.setSharing(clubID: club.id, readID: read.id, enabled: enabled, presence: presence)
            if enabled, let book = localBook {
                let fraction = book.mediaType == .ebook ? book.canonicalEbookProgress : book.canonicalProgress
                store.record(book: book, fraction: fraction, active: false)
            }
        }
    }

    private func complete(_ checkpoint: ClubCheckpoint) {
        run {
            try await store.change("\(base)/checkpoints/\(checkpoint.id)/complete", body: [String: String]())
            notice = "Reached \(checkpoint.label)"
        }
    }

    private func reload() async {
        do {
            let details: ClubReadDetails = try await store.request(base)
            self.details = details
            await store.syncSettings(with: details, clubID: club.id, book: localBook)
            error = nil
        } catch is CancellationError {
        } catch let error as ClubsResponseError where error.status == 404 {
            details = nil
            self.error = error.localizedDescription
        } catch { self.error = error.localizedDescription }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        guard !busy, copyDownloadTask == nil else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await action(); await reload() }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct ClubTrack: View {
    let club: ClubDetails
    let details: ClubReadDetails
    let account: ClubAccount
    @Environment(\.hearth) private var hearth

    var body: some View {
        ClubPanel {
            Text("The Track").font(.headline).accessibilityAddTraits(.isHeader)
            if markers.isEmpty {
                Text("Shared progress and check-ins will appear here.").foregroundStyle(.secondary)
            } else {
                track
                HStack {
                    Text("Start")
                    Spacer()
                    Text("Finish")
                }
                .font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            ForEach(club.members, id: \.id) { member in
                memberStatus(member)
            }
        }
        .accessibilityIdentifier("clubs-track")
    }

    private struct Marker: Identifiable {
        var id: String { member.id }
        let member: ClubAccount
        let fraction: Double
    }

    private var markers: [Marker] {
        club.members.compactMap { member in
            if let progress = details.progress.first(where: { $0.accountID == member.id }) {
                return Marker(member: member, fraction: progress.fraction)
            }
            let done = details.completed(by: member.id)
            guard let index = details.checkpoints.lastIndex(where: { done.contains($0.id) }) else { return nil }
            let step = details.checkpoints[index]
            return Marker(member: member, fraction: step.trackPosition ?? Double(index + 1) / Double(details.checkpoints.count + 1))
        }
    }

    private var track: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width - 32)
            let visible = Array(markers.prefix(16))
            let lanes = laneAssignments(visible, width: width)
            ZStack(alignment: .topLeading) {
                Capsule().fill(hearth.hairline).frame(width: width, height: 3).offset(x: 16, y: 116)
                ForEach(details.checkpoints.filter { $0.trackPosition != nil }) { checkpoint in
                    Image(systemName: "flag.fill").font(.caption2).foregroundStyle(hearth.ember)
                        .position(x: 16 + width * (checkpoint.trackPosition ?? 0), y: 109)
                }
                ForEach(visible) { marker in
                    ClubAvatar(name: marker.member.name, isYou: marker.member.id == account.id)
                        .position(x: 16 + width * marker.fraction, y: 89 - CGFloat(lanes[marker.id, default: 0]) * 29)
                }
            }
        }
        .frame(height: 122)
        .accessibilityHidden(true)
    }

    private func laneAssignments(_ markers: [Marker], width: CGFloat) -> [String: Int] {
        var end: [CGFloat] = [-40, -40, -40]
        var lanes: [String: Int] = [:]
        for marker in markers.sorted(by: { $0.fraction < $1.fraction }) {
            let x = width * marker.fraction
            let lane = end.firstIndex(where: { x - $0 >= 31 }) ?? (end.firstIndex(of: end.min() ?? 0) ?? 0)
            lanes[marker.id] = lane
            end[lane] = x
        }
        return lanes
    }

    private func memberStatus(_ member: ClubAccount) -> some View {
        let done = details.completed(by: member.id)
        let position = details.progress.first { $0.accountID == member.id }
        let latest = details.checkpoints.last { done.contains($0.id) }
        let next = details.checkpoints.first { !done.contains($0.id) }
        let active = position?.activeUntil.map { $0 > .now } ?? false
        let status: String? = {
            if details.checkpoints.isEmpty || details.read.closedAt != nil { return nil }
            if next == nil { return "Plan complete" }
            if next?.dueAt.map({ $0 < .now }) == true { return "Catching up" }
            if latest?.dueAt.map({ $0 > .now }) == true { return "Ahead" }
            if next?.dueAt != nil { return "On track" }
            return nil
        }()
        return HStack(alignment: .top, spacing: 10) {
            ClubAvatar(name: member.name, isYou: member.id == account.id)
            VStack(alignment: .leading, spacing: 3) {
                Text(member.id == account.id ? "\(member.name) (you)" : member.name).font(.subheadline.weight(.semibold))
                if let latest { Text("Reached \(latest.label)").font(.caption).foregroundStyle(.secondary) }
                if active { Label("Reading now", systemImage: "circle.fill").font(.caption).foregroundStyle(.green) }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                if let position {
                    Text("~\(position.fraction, format: .percent.precision(.fractionLength(0)))")
                        .font(.subheadline.monospacedDigit())
                        .accessibilityLabel("Approximately \(position.fraction.formatted(.percent.precision(.fractionLength(0))))")
                }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                if position == nil, latest == nil { Text("No check-in yet").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
