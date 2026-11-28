#if os(iOS)
import Combine
import Foundation
import Observation
import UserNotifications

@Observable
final class ClubsStore {
    private struct Pending: Codable {
        let update: ClubProgressUpdate
        let completedCheckpointID: String?
    }

    private struct LocalState: Codable {
        var copies: [String: ClubCopy] = [:]
        var pending: [String: Pending] = [:]
        var reminders: Set<String> = []
    }

    private let api: ClubsAPI
    private let keychain: ClubCredentialStore
    private let defaults: UserDefaults
    private let storageKey: String
    private let notificationPrefix: String
    private var credentials: ClubCredentials?
    private(set) var account: ClubAccount?
    private(set) var clubSummaries: [ClubSummary] = []
    private(set) var storageError: String?
    private var local = LocalState()
    @ObservationIgnored private var playbackSource: (() -> AnyPublisher<PlaybackSnapshot, Never>?)?
    @ObservationIgnored private var playbackObservation: AnyCancellable?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var lastPosition: [String: ClubProgressUpdate] = [:]
    @ObservationIgnored private var lastChapter: [String: String] = [:]
    @ObservationIgnored private var lastSent: [String: Date] = [:]
    @ObservationIgnored private var retired = false
    @ObservationIgnored private var clubRefreshVersion = 0
    @ObservationIgnored private var passageSearch: (bookID: String, text: String, expires: Date)?
    @ObservationIgnored private var pendingBook: (Book, position: TimeInterval?, passage: String?)?

    func queueBook(_ book: Book, position: TimeInterval? = nil, passage: String? = nil) {
        pendingBook = (book, position, passage)
    }

    func openQueuedBook(using playback: PlaybackEngine) {
        guard let (book, position, passage) = pendingBook, !retired else { return }
        pendingBook = nil
        if let passage {
            passageSearch = (book.uniqueId, passage, .now.addingTimeInterval(90))
            playback.openEbook(book)
        } else if book.mediaType == .ebook {
            playback.openEbook(book)
        } else {
            playback.play(book, from: position)
        }
    }

    func consumePassageSearch(for book: Book) -> String? {
        guard let passageSearch, passageSearch.bookID == book.uniqueId else { return nil }
        self.passageSearch = nil
        return passageSearch.expires > .now ? passageSearch.text : nil
    }


    init(profileID: String, defaults: UserDefaults, url: URL) {
        api = ClubsAPI(baseURL: url)
        keychain = ClubCredentialStore(profileID: profileID, service: url)
        self.defaults = defaults
        storageKey = "bookClubs.local.\(url.absoluteString)"
        notificationPrefix = "enve.clubs.\(profileID)."
        do {
            credentials = try keychain.load()
            account = credentials?.account
            if let account, let data = defaults.data(forKey: storageKey + "." + account.id) {
                local = (try? JSONDecoder().decode(LocalState.self, from: data)) ?? LocalState()
            }
        } catch {
            storageError = error.localizedDescription
        }
        scheduleFlush()
    }

    func bindPlayback(_ source: @escaping () -> AnyPublisher<PlaybackSnapshot, Never>?) {
        playbackSource = source
        updatePlaybackObservation()
    }

    private func updatePlaybackObservation() {
        guard account != nil, local.copies.values.contains(where: { $0.sharing?.epoch != nil }) else {
            playbackObservation = nil
            return
        }
        guard playbackObservation == nil else { return }
        playbackObservation = playbackSource?()?
            .throttle(for: .seconds(8), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] snapshot in
                guard let book = snapshot.currentBook, book.mediaType == .audiobook,
                      snapshot.isLoaded, !snapshot.isLoading, !snapshot.isOverlayPlaybackActive,
                      snapshot.duration.isFinite, snapshot.duration > 0 else { return }
                self?.record(book: book, fraction: snapshot.position / snapshot.duration,
                             active: snapshot.isPlaying, audioDuration: snapshot.duration)
            }
    }

    var recoveryKey: String? { credentials?.recoveryKey }

    func authorize(name: String? = nil, recoveryKey: String? = nil) async throws {
        let path = name == nil ? "sessions" : "accounts"
        let body = name.map { ["name": $0] } ?? ["recoveryKey": recoveryKey ?? ""]
        let credentials: ClubCredentials = try await api.request(path, method: "POST", token: nil, body: body)
        guard !retired, !Task.isCancelled else { throw CancellationError() }
        try keychain.save(credentials)
        self.credentials = credentials
        clubSummaries = []
        account = credentials.account
        storageError = nil
        if let data = defaults.data(forKey: storageKey + "." + credentials.account.id) {
            local = (try? JSONDecoder().decode(LocalState.self, from: data)) ?? LocalState()
        } else {
            local = LocalState()
        }
        scheduleFlush()
        updatePlaybackObservation()
    }

    func endSession(deleting: Bool) async throws {
        let _: ClubsAPI.OK = try await request(deleting ? "me" : "me/session", method: "DELETE")
        if let account, deleting { defaults.removeObject(forKey: storageKey + "." + account.id) }
        for clubID in local.reminders { await clearReminders(clubID: clubID) }
        try keychain.remove()
        credentials = nil
        clubSummaries = []
        account = nil
        local = LocalState()
        playbackObservation = nil
        lastPosition = [:]
        lastChapter = [:]
        lastSent = [:]
        worker?.cancel()
        worker = nil
    }

    func rotateRecoveryKey() async throws {
        let result: ClubsAPI.Recovery = try await request("me/recovery", method: "POST")
        guard var credentials else { return }
        credentials.recoveryKey = result.recoveryKey
        self.credentials = credentials
        try keychain.save(credentials)
    }

    func request<Value: Decodable>(
        _ path: String,
        method: String = "GET",
        body: (any Encodable)? = nil,
        query: [URLQueryItem] = []
    ) async throws -> Value {
        try await authenticated { token in
            try await api.request(path, method: method, token: token, body: body, query: query)
        }
    }

    private func authenticated<Value>(_ operation: @MainActor (String) async throws -> Value) async throws -> Value {
        guard !retired else { throw CancellationError() }
        guard let credentials, account != nil else { throw ClubsResponseError(status: 401, message: "Sign in to Clubs.") }
        do {
            let result = try await operation(credentials.token)
            guard !retired, !Task.isCancelled, account != nil,
                  self.credentials?.token == credentials.token else { throw CancellationError() }
            return result
        } catch let error as ClubsResponseError where error.status == 401 {
            if self.credentials?.token == credentials.token {
                clubSummaries = []
                account = nil
                playbackObservation = nil
            }
            throw error
        }
    }

    func refreshClubs() async throws {
        clubRefreshVersion += 1
        let version = clubRefreshVersion
        let summaries: [ClubSummary] = try await request("clubs")
        if version == clubRefreshVersion { clubSummaries = summaries }
    }

    func change(_ path: String, method: String = "PUT", body: (any Encodable)? = nil) async throws {
        let _: ClubsAPI.OK = try await request(path, method: method, body: body)
    }

    func downloadHostedCopy(
        _ hostedCopy: ClubHostedCopy,
        clubID: String,
        read: ClubReadDetails,
        session: ProfileSession,
        progress: (ClubHostedCopyDownloadProgress) -> Void
    ) async throws -> Book {
        let files = hostedCopy.files.sorted { $0.index < $1.index }
        let isAudio = hostedCopy.format == "audiobook"
        guard UUID(uuidString: clubID) != nil, UUID(uuidString: read.read.id) != nil,
              UUID(uuidString: hostedCopy.id) != nil, let firstIndex = files.first?.index, (0...1).contains(firstIndex),
              isAudio || hostedCopy.format == "ebook" && files.count == 1 else {
            throw invalidHostedCopy
        }
        for (index, file) in files.enumerated() {
            let pathExtension = (file.name as NSString).pathExtension.lowercased()
            let supported = isAudio
                ? AudiobookFormat.from(fileExtension: pathExtension) != nil
                : EbookFormat.from(fileExtension: pathExtension) != nil
            guard firstIndex + index == file.index,
                  (1...ImportLimits.maxImportedMediaFileBytes).contains(file.bytes),
                  file.name.utf8.count <= 240, !file.name.hasPrefix("."),
                  file.name.rangeOfCharacter(from: .controlCharacters.union(CharacterSet(charactersIn: "/\\"))) == nil,
                  !file.contentType.isEmpty, file.contentType.utf8.count <= 127,
                  file.contentType.rangeOfCharacter(from: .controlCharacters) == nil,
                  supported else { throw invalidHostedCopy }
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: directory) }

        let readID = read.read.id
        let base = "clubs/\(clubID)/reads/\(readID)"
        let accountID = account?.id
        let downloaded: [URL] = try await authenticated { token in
            var result: [URL] = []
            for file in files {
                try Task.checkCancellation()
                progress(.downloading(completed: result.count, total: files.count))
                // The local importer sorts audio files by filename.
                let name = files.count > 1 ? String(format: "%09d ", file.index) + file.name : file.name
                let destination = directory.appendingPathComponent(name)
                try await api.download("\(base)/copy/\(hostedCopy.id)/files/\(file.index)", token: token, file: file, destination: destination)
                result.append(destination)
            }
            return result
        }

        var fresh: ClubReadDetails = try await request(base)
        guard account?.id == accountID, !session.isRetired else { throw CancellationError() }
        progress(.importing)
        let urls: [URL]
        var audioDestination: URL?
        var didImportAudio = false
        defer {
            if let audioDestination, !didImportAudio {
                try? fileManager.removeItem(at: audioDestination)
            }
        }
        if isAudio {
            let editionID = String(UUID().uuidString.prefix(12))
            let title = "\(audioImportComponent(hostedCopy.title, fallback: fresh.read.title)) (Club Copy \(editionID))"
            let author = audioImportComponent(fresh.read.author ?? "", fallback: "Unknown Author")
            let metadata = LocalBookMetadata(title: title, author: author)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(metadata).write(to: directory.appendingPathComponent("metadata.json"))

            let parent = session.storage.documentsDirectory.appendingPathComponent("Individual_Audiobooks", isDirectory: true)
                .appendingPathComponent(author, isDirectory: true)
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            let destination = parent.appendingPathComponent(title, isDirectory: true)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
            audioDestination = destination
            urls = [directory]
        } else {
            urls = downloaded
        }
        let imported = try await session.engine.sources.importFiles(urls: urls, mode: .groupByFolder)
        guard let book = imported.first else {
            throw ClubsResponseError(status: 422, message: "Enve could not import the club copy. Check your free storage or ask the host to try another file.")
        }
        didImportAudio = isAudio
        try Task.checkCancellation()
        guard !retired, account?.id == accountID, !session.isRetired else { throw CancellationError() }
        if let previous = copy(for: readID), previous.bookID != book.uniqueId,
           fresh.read.closedAt == nil, fresh.sharing?.epoch != nil {
            try await setSharing(clubID: clubID, readID: readID, enabled: false, presence: false)
            fresh = try await request(base)
        }
        link(book, clubID: clubID, read: fresh)
        return book
    }

    private var invalidHostedCopy: ClubsResponseError {
        ClubsResponseError(status: 422, message: "This club copy has an unsupported file listing. Ask the host to try another file.")
    }

    private func audioImportComponent(_ name: String, fallback: String) -> String {
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: ":/\\?%*|\"<>"))
        for value in [name, fallback] {
            let shortened = String(decoding: value.utf8.prefix(192), as: UTF8.self)
            let component = shortened.components(separatedBy: invalid).joined(separator: "_").clubTrimmed
            if !component.isEmpty && !component.hasPrefix(".") { return component }
        }
        return "Club Book"
    }

    func copy(for readID: String) -> ClubCopy? { local.copies[readID] }
    func linkedCopies(for book: Book) -> [ClubCopy] { local.copies.values.filter { $0.bookID == book.uniqueId } }

    func link(_ book: Book, clubID: String, read: ClubReadDetails) {
        let readID = read.read.id
        let previous = local.copies[readID]
        if previous?.bookID != book.uniqueId {
            local.pending.removeValue(forKey: readID)
            lastPosition.removeValue(forKey: readID)
            lastChapter.removeValue(forKey: readID)
        }
        var copy = ClubCopy(clubID: clubID, readID: readID, bookID: book.uniqueId,
                            sharing: read.read.closedAt == nil ? read.sharing : nil)
        updateCheckpoints(&copy, book: book, checkpoints: read.checkpoints)
        local.copies[readID] = copy
        save()
        updatePlaybackObservation()
    }

    func syncSettings(with read: ClubReadDetails, clubID: String, book: Book?) async {
        if let book, var copy = local.copies[read.read.id] {
            if copy.sharing?.epoch != read.sharing?.epoch {
                local.pending.removeValue(forKey: read.read.id)
                lastPosition.removeValue(forKey: read.read.id)
                lastChapter.removeValue(forKey: read.read.id)
            }
            copy.sharing = read.read.closedAt == nil ? read.sharing : nil
            updateCheckpoints(&copy, book: book, checkpoints: read.checkpoints)
            local.copies[read.read.id] = copy
            save()
        }
        if local.reminders.contains(clubID), read.read.closedAt == nil {
            await replaceReminders(clubID: clubID, read: read)
        }
    }

    func setSharing(clubID: String, readID: String, enabled: Bool, presence: Bool) async throws {
        let sharing: ClubSharing = try await request("clubs/\(clubID)/reads/\(readID)/sharing", method: "PUT",
                                                     body: ["enabled": enabled, "presence": presence])
        local.copies[readID]?.sharing = sharing.epoch == nil ? nil : sharing
        local.pending.removeValue(forKey: readID)
        lastPosition.removeValue(forKey: readID)
        lastChapter.removeValue(forKey: readID)
        save()
        updatePlaybackObservation()
    }

    func unlink(clubID: String, readID: String) async throws {
        try await setSharing(clubID: clubID, readID: readID, enabled: false, presence: false)
        local.copies.removeValue(forKey: readID)
        save()
    }

    func removeLocalClub(_ clubID: String) async {
        clubRefreshVersion += 1
        clubSummaries.removeAll { $0.id == clubID }
        for copy in local.copies.values.filter({ $0.clubID == clubID }) {
            local.copies.removeValue(forKey: copy.readID)
            local.pending.removeValue(forKey: copy.readID)
            lastPosition.removeValue(forKey: copy.readID)
            lastChapter.removeValue(forKey: copy.readID)
            lastSent.removeValue(forKey: copy.readID)
        }
        local.reminders.remove(clubID)
        await clearReminders(clubID: clubID)
        save()
    }

    func sharesProgress(for book: Book) -> Bool {
        account != nil && local.copies.values.contains { $0.bookID == book.uniqueId && $0.sharing?.epoch != nil }
    }

    func record(book: Book, fraction: Double, at date: Date = .now, active: Bool,
                audioDuration: TimeInterval? = nil, chapter: String? = nil, chapterOrder: [String] = []) {
        guard account != nil, !retired, fraction.isFinite else { return }
        let fraction = min(max(fraction, 0), 1)
        var changed = false
        for copy in local.copies.values where copy.bookID == book.uniqueId {
            guard let epoch = copy.sharing?.epoch else { continue }
            let previous = lastPosition[copy.readID]
            guard previous.map({ date > $0.observedAt }) ?? true else { continue }
            let active = active && copy.sharing?.presence == true
            let update = ClubProgressUpdate(epoch: epoch, fraction: fraction, observedAt: date, active: active)
            lastPosition[copy.readID] = update
            let existing = local.pending[copy.readID]
            var completion = existing?.completedCheckpointID
            var crossed: String?
            if let previous, let audioDuration, audioDuration.isFinite, audioDuration > 0 {
                let elapsed = date.timeIntervalSince(previous.observedAt)
                let advanced = (fraction - previous.fraction) * audioDuration
                if elapsed < 120, advanced > 0, advanced <= elapsed * 4 + 3 {
                    crossed = copy.checkpointOrder.last { id in
                        copy.checkpointEnds[id].map { previous.fraction < $0 && fraction >= $0 } ?? false
                    }
                }
            }
            if let chapter {
                let current = Self.chapterKey(chapter)
                if let previous = lastChapter[copy.readID], previous != current,
                   let index = chapterOrder.firstIndex(of: previous), chapterOrder.lastIndex(of: previous) == index,
                   chapterOrder.indices.contains(index + 1), chapterOrder[index + 1] == current,
                   chapterOrder.firstIndex(of: current) == chapterOrder.lastIndex(of: current) {
                    crossed = copy.checkpointOrder.last { copy.checkpointKeys[$0] == previous }
                }
                lastChapter[copy.readID] = current
            }
            if let crossed, let rank = copy.checkpointOrder.firstIndex(of: crossed),
               rank > (completion.flatMap { copy.checkpointOrder.firstIndex(of: $0) } ?? -1) {
                completion = crossed
            }
            if let previous, fraction == previous.fraction, active == previous.active,
               (!active || date.timeIntervalSince(lastSent[copy.readID] ?? .distantPast) < 30),
               completion == existing?.completedCheckpointID { continue }
            local.pending[copy.readID] = Pending(update: update, completedCheckpointID: completion)
            changed = true
        }
        if changed { save(); scheduleFlush() }
    }

    private func updateCheckpoints(_ copy: inout ClubCopy, book: Book, checkpoints: [ClubCheckpoint]) {
        copy.checkpointOrder = checkpoints.map(\.id)
        copy.checkpointKeys = Dictionary(uniqueKeysWithValues: checkpoints.compactMap { checkpoint in
            let key = checkpoint.chapterKey ?? Self.chapterKey(checkpoint.label)
            return key.isEmpty ? nil : (checkpoint.id, key)
        })
        copy.checkpointEnds = [:]
        guard book.mediaType == .audiobook, let duration = book.duration, duration > 0,
              let chapters = book.chapters else { return }
        let chapterGroups = Dictionary(grouping: chapters, by: { Self.chapterKey($0.title) })
        var previousEnd = 0.0
        for checkpoint in checkpoints {
            guard let key = copy.checkpointKeys[checkpoint.id], let matches = chapterGroups[key], matches.count == 1,
                  let chapter = matches.first, chapter.end > previousEnd, chapter.end <= duration else { continue }
            copy.checkpointEnds[checkpoint.id] = chapter.end / duration
            previousEnd = chapter.end
        }
    }

    static func chapterKey(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    private func scheduleFlush() {
        guard worker == nil, account != nil, !local.pending.isEmpty else { return }
        worker = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            await flush()
        }
    }

    private func flush() async {
        var shouldRetry = false
        for (readID, pending) in local.pending {
            guard !Task.isCancelled, !retired, account != nil else { break }
            guard let copy = local.copies[readID], copy.sharing?.epoch == pending.update.epoch else {
                local.pending.removeValue(forKey: readID)
                continue
            }
            if Date.now.timeIntervalSince(lastSent[readID] ?? .distantPast) < 25 { continue }
            let path = "clubs/\(copy.clubID)/reads/\(readID)"
            do {
                try await change(path + "/progress", body: pending.update)
                if let checkpointID = pending.completedCheckpointID,
                   local.copies[readID]?.sharing?.epoch == pending.update.epoch {
                    try await change(path + "/checkpoints/\(checkpointID)/complete", body: ["epoch": pending.update.epoch])
                }
                lastSent[readID] = .now
                if local.pending[readID]?.update.observedAt == pending.update.observedAt { local.pending.removeValue(forKey: readID) }
            } catch let error as ClubsResponseError where [400, 403, 404, 409].contains(error.status) {
                if local.pending[readID]?.update.epoch == pending.update.epoch {
                    local.pending.removeValue(forKey: readID)
                    if error.status != 400 { local.copies[readID]?.sharing = nil }
                }
            } catch {
                shouldRetry = true
            }
        }
        guard !Task.isCancelled, !retired else { return }
        save()
        worker = nil
        guard !retired, account != nil, !local.pending.isEmpty else { return }
        worker = Task { [weak self] in
            try? await Task.sleep(for: .seconds(shouldRetry ? 45 : 25))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    func remindersEnabled(clubID: String) -> Bool { local.reminders.contains(clubID) }

    func setReminders(_ enabled: Bool, clubID: String, read: ClubReadDetails) async throws {
        if enabled {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            guard allowed else { throw ClubsResponseError(status: 0, message: "Allow notifications in Settings to get reading reminders.") }
            local.reminders.insert(clubID)
            await replaceReminders(clubID: clubID, read: read)
        } else {
            local.reminders.remove(clubID)
            await clearReminders(clubID: clubID)
        }
        save()
    }

    private func replaceReminders(clubID: String, read: ClubReadDetails) async {
        guard let account else { return }
        await clearReminders(clubID: clubID)
        let completed = read.completed(by: account.id)
        let center = UNUserNotificationCenter.current()
        for checkpoint in read.checkpoints where !completed.contains(checkpoint.id) {
            guard let due = checkpoint.dueAt, due > .now else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Book club checkpoint"
            content.body = "Your next reading checkpoint is coming up. Open Clubs to see the plan."
            let early = due.addingTimeInterval(-3600)
            let interval = max(1, (early > .now ? early : due).timeIntervalSinceNow)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "\(notificationPrefix)\(clubID).\(checkpoint.id)", content: content, trigger: trigger))
        }
    }

    private func clearReminders(clubID: String) async {
        let center = UNUserNotificationCenter.current()
        let prefix = notificationPrefix + clubID + "."
        let pending = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier))
    }

    private func save() {
        guard let account, let data = try? JSONEncoder().encode(local) else { return }
        defaults.set(data, forKey: storageKey + "." + account.id)
    }

    func retire() {
        retired = true
        clubSummaries = []
        worker?.cancel()
        worker = nil
        playbackObservation = nil
        api.invalidate()
    }
}
#endif
