import CryptoKit
import Foundation

struct EpubBridgeTextQuote: Codable, Equatable, Sendable {
    let exact: String
    let prefix: String?
    let suffix: String?

    init?(exact: String?, prefix: String?, suffix: String?) {
        guard let exact = exact?.trimmingCharacters(in: .whitespacesAndNewlines),
            !exact.isEmpty
        else { return nil }
        self.exact = exact
        self.prefix = prefix?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.suffix = suffix?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

struct EpubBridgeDOMRange: Codable, Equatable, Sendable {
    struct Point: Codable, Equatable, Sendable {
        let cssSelector: String
        let textNodeIndex: Int
        let charOffset: Int?
    }

    let start: Point
    let end: Point?
}

struct EpubBridgePosition: Equatable, Sendable {
    var href: String
    var epubCFI: String?
    var partialCFI: String?
    var cssSelector: String?
    var domRange: EpubBridgeDOMRange?
    var resourceProgression: Double?
    var totalProgression: Double
    var textQuote: EpubBridgeTextQuote?
    var readiumLocatorJSON: String?

    init(
        href: String,
        epubCFI: String?,
        partialCFI: String?,
        cssSelector: String?,
        domRange: EpubBridgeDOMRange?,
        resourceProgression: Double?,
        totalProgression: Double,
        textQuote: EpubBridgeTextQuote?,
        readiumLocatorJSON: String?
    ) {
        self.href = href
        self.epubCFI = epubCFI
        self.partialCFI = partialCFI
        self.cssSelector = cssSelector
        self.domRange = domRange
        self.resourceProgression = resourceProgression
        self.totalProgression = totalProgression
        self.textQuote = textQuote
        self.readiumLocatorJSON = readiumLocatorJSON
    }

    init?(
        readiumLocatorJSON: String,
        fallbackProgression: Double? = nil
    ) {
        guard let data = readiumLocatorJSON.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let href = json["href"] as? String,
            let locations = json["locations"] as? [String: Any]
        else {
            return nil
        }

        let resourceProgression = Self.fraction(locations["progression"])
        let totalProgression =
            Self.fraction(locations["totalProgression"])
            ?? fallbackProgression.map { min(max($0, 0), 1) }
        guard let totalProgression else { return nil }

        let text = json["text"] as? [String: Any]
        let domRange: EpubBridgeDOMRange? = {
            guard let object = locations["domRange"],
                JSONSerialization.isValidJSONObject(object),
                let data = try? JSONSerialization.data(withJSONObject: object)
            else {
                return nil
            }
            return try? JSONDecoder().decode(EpubBridgeDOMRange.self, from: data)
        }()

        self.href = href
        self.epubCFI = EpubLocationBridge.epubCFI(from: readiumLocatorJSON)
        self.partialCFI = (locations["partialCfi"] as? String)?.nilIfEmpty
        self.cssSelector = (locations["cssSelector"] as? String)?.nilIfEmpty
        self.domRange = domRange
        self.resourceProgression = resourceProgression
        self.totalProgression = totalProgression
        self.textQuote = EpubBridgeTextQuote(
            exact: text?["highlight"] as? String,
            prefix: text?["before"] as? String,
            suffix: text?["after"] as? String
        )
        self.readiumLocatorJSON = readiumLocatorJSON
    }

    func sharesSemanticLocation(with other: EpubBridgePosition) -> Bool {
        if let epubCFI, let otherCFI = other.epubCFI {
            guard let lhs = EpubLocationBridge.normalizedEPUBCFI(epubCFI),
                let rhs = EpubLocationBridge.normalizedEPUBCFI(otherCFI)
            else {
                return false
            }
            return lhs == rhs
        }
        guard sharesResource(with: other) else {
            return false
        }
        if let domRange, let otherRange = other.domRange {
            return domRange == otherRange
        }
        if let textQuote, let otherQuote = other.textQuote {
            return textQuote.semanticallyMatches(otherQuote)
        }
        if let cssSelector, let otherSelector = other.cssSelector {
            return cssSelector == otherSelector
        }
        if let resourceProgression, let otherProgression = other.resourceProgression {
            return abs(resourceProgression - otherProgression) <= 0.01
        }
        return false
    }

    var hasPortableAnchor: Bool {
        textQuote != nil || domRange != nil || cssSelector?.isEmpty == false
    }

    func sharesResource(with other: EpubBridgePosition) -> Bool {
        let lhs = EpubLocationBridge.normalizedHref(href)
        let rhs = EpubLocationBridge.normalizedHref(other.href)
        return lhs == rhs
            || lhs.hasSuffix("/\(rhs)")
            || rhs.hasSuffix("/\(lhs)")
    }

    private static func fraction(_ rawValue: Any?) -> Double? {
        guard let number = rawValue as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }
}

private extension EpubBridgeTextQuote {
    func semanticallyMatches(_ other: EpubBridgeTextQuote) -> Bool {
        guard exact.coalescingWhitespace == other.exact.coalescingWhitespace else {
            return false
        }
        if let prefix, let otherPrefix = other.prefix {
            let lhs = prefix.coalescingWhitespace
            let rhs = otherPrefix.coalescingWhitespace
            guard lhs.hasSuffix(rhs) || rhs.hasSuffix(lhs) else { return false }
        }
        if let suffix, let otherSuffix = other.suffix {
            let lhs = suffix.coalescingWhitespace
            let rhs = otherSuffix.coalescingWhitespace
            guard lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs) else { return false }
        }
        return true
    }
}

struct EpubBridgeCheckpoint: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let bookKey: String
    let publicationFingerprint: String
    let revision: UInt64
    let writerEpoch: UInt64
    let observedAtMs: Int64
    let sourceEngine: ReaderEngineKind
    let href: String
    let epubCFI: String?
    let partialCFI: String?
    let cssSelector: String?
    let domRange: EpubBridgeDOMRange?
    let resourceProgression: Double?
    let totalProgression: Double
    let textQuote: EpubBridgeTextQuote?
    let readiumLocatorJSON: String?

    var position: EpubBridgePosition {
        EpubBridgePosition(
            href: href,
            epubCFI: epubCFI,
            partialCFI: partialCFI,
            cssSelector: cssSelector,
            domRange: domRange,
            resourceProgression: resourceProgression,
            totalProgression: totalProgression,
            textQuote: textQuote,
            readiumLocatorJSON: readiumLocatorJSON
        )
    }

    fileprivate init(
        bookKey: String,
        publicationFingerprint: String,
        revision: UInt64,
        writerEpoch: UInt64,
        observedAtMs: Int64,
        sourceEngine: ReaderEngineKind,
        position: EpubBridgePosition
    ) throws {
        guard !bookKey.isEmpty, !publicationFingerprint.isEmpty else {
            throw EpubBridgeCheckpointError.invalidIdentity
        }
        guard !EpubLocationBridge.normalizedHref(position.href).isEmpty else {
            throw EpubBridgeCheckpointError.missingHref
        }
        self.schemaVersion = 1
        self.bookKey = bookKey
        self.publicationFingerprint = publicationFingerprint
        self.revision = revision
        self.writerEpoch = writerEpoch
        self.observedAtMs = observedAtMs
        self.sourceEngine = sourceEngine
        self.href = position.href
        self.epubCFI = sourceEngine == .foliate ? position.epubCFI : nil
        self.partialCFI = sourceEngine == .foliate ? position.partialCFI : nil
        self.cssSelector = position.cssSelector
        self.domRange = position.domRange
        self.resourceProgression = position.resourceProgression
        self.totalProgression = position.totalProgression
        self.textQuote = position.textQuote
        let rawLocatorJSON =
            position.readiumLocatorJSON
            ?? EpubLocationBridge.readiumLocator(from: position)
        let locatorJSON =
            sourceEngine == .readium
            ? EpubLocationBridge.removingEPUBCFI(from: rawLocatorJSON)
            : rawLocatorJSON
        self.readiumLocatorJSON = EpubLocationBridge.markingSourceEngine(
            sourceEngine,
            in: locatorJSON
        )
    }
}

struct EpubBridgeWriteLease: Equatable, Sendable {
    let bookKey: String
    let publicationFingerprint: String
    let engine: ReaderEngineKind
    let writerEpoch: UInt64
}

enum EpubBridgeCheckpointError: Error, Equatable {
    case invalidIdentity
    case staleWriter
    case staleRevision
    case restoreNotConfirmed
    case userInteractionRequired
    case invalidLocator
    case missingHref
    case zeroRequiresUserIntent
}

@MainActor
final class EpubBridgeCheckpointStore {
    static let shared = EpubBridgeCheckpointStore()

    private struct StoredState: Codable {
        let bookKey: String
        let publicationFingerprint: String
        var writerEpoch: UInt64
        var checkpoint: EpubBridgeCheckpoint?
    }

    private let directoryURL: URL

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.directoryURL =
            directoryURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EpubBridgeCheckpoints", isDirectory: true)
        try? fileManager.createDirectory(
            at: self.directoryURL,
            withIntermediateDirectories: true
        )
    }

    func checkpoint(bookKey: String, publicationFingerprint: String) -> EpubBridgeCheckpoint? {
        storedState(bookKey: bookKey, fingerprint: publicationFingerprint)?.checkpoint
    }

    func beginWriteSession(
        bookKey: String,
        publicationFingerprint: String,
        engine: ReaderEngineKind
    ) -> EpubBridgeWriteLease {
        var state =
            storedState(bookKey: bookKey, fingerprint: publicationFingerprint)
            ?? StoredState(
                bookKey: bookKey,
                publicationFingerprint: publicationFingerprint,
                writerEpoch: 0,
                checkpoint: nil
            )
        state.writerEpoch &+= 1
        persist(state)
        return EpubBridgeWriteLease(
            bookKey: bookKey,
            publicationFingerprint: publicationFingerprint,
            engine: engine,
            writerEpoch: state.writerEpoch
        )
    }

    func commit(
        position: EpubBridgePosition,
        lease: EpubBridgeWriteLease,
        expectedRevision: UInt64,
        observedAt: Date,
        allowZero: Bool
    ) throws -> EpubBridgeCheckpoint {
        guard
            var state = storedState(
                bookKey: lease.bookKey,
                fingerprint: lease.publicationFingerprint
            ),
            state.writerEpoch == lease.writerEpoch
        else {
            throw EpubBridgeCheckpointError.staleWriter
        }
        let currentRevision = state.checkpoint?.revision ?? 0
        guard currentRevision == expectedRevision else {
            throw EpubBridgeCheckpointError.staleRevision
        }
        if position.totalProgression <= 0.001,
            (state.checkpoint?.totalProgression ?? 0) > 0.001,
            !allowZero
        {
            throw EpubBridgeCheckpointError.zeroRequiresUserIntent
        }

        let checkpoint = try EpubBridgeCheckpoint(
            bookKey: lease.bookKey,
            publicationFingerprint: lease.publicationFingerprint,
            revision: currentRevision &+ 1,
            writerEpoch: lease.writerEpoch,
            observedAtMs: Int64(observedAt.timeIntervalSince1970 * 1_000),
            sourceEngine: lease.engine,
            position: position
        )
        state.checkpoint = checkpoint
        persist(state)
        return checkpoint
    }

    func revoke(_ lease: EpubBridgeWriteLease) {
        guard
            var state = storedState(
                bookKey: lease.bookKey,
                fingerprint: lease.publicationFingerprint
            ), state.writerEpoch == lease.writerEpoch
        else { return }
        state.writerEpoch &+= 1
        persist(state)
    }

    private func storageID(bookKey: String, fingerprint: String) -> String {
        let digest = SHA256.hash(data: Data("\(bookKey)\0\(fingerprint)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func storedState(bookKey: String, fingerprint: String) -> StoredState? {
        let url = stateURL(bookKey: bookKey, fingerprint: fingerprint)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StoredState.self, from: data)
    }

    private func persist(_ state: StoredState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(
            to: stateURL(bookKey: state.bookKey, fingerprint: state.publicationFingerprint),
            options: .atomic
        )
    }

    private func stateURL(bookKey: String, fingerprint: String) -> URL {
        directoryURL
            .appendingPathComponent(storageID(bookKey: bookKey, fingerprint: fingerprint))
            .appendingPathExtension("json")
    }
}

@MainActor
final class EpubBridgeSession {
    private enum Phase {
        case restoring
        case active
        case closed
    }

    private let store: EpubBridgeCheckpointStore
    private let lease: EpubBridgeWriteLease
    private var phase: Phase = .restoring
    private var expectedRevision: UInt64
    private var restoreTarget: EpubBridgePosition?
    private var userInteractedAfterRestore = false
    private(set) var checkpoint: EpubBridgeCheckpoint?

    init(
        bookKey: String,
        publicationFingerprint: String,
        engine: ReaderEngineKind,
        store: EpubBridgeCheckpointStore = .shared
    ) {
        self.store = store
        checkpoint = store.checkpoint(
            bookKey: bookKey,
            publicationFingerprint: publicationFingerprint
        )
        expectedRevision = checkpoint?.revision ?? 0
        restoreTarget = checkpoint?.position
        lease = store.beginWriteSession(
            bookKey: bookKey,
            publicationFingerprint: publicationFingerprint,
            engine: engine
        )
    }

    var initialReadiumLocatorJSON: String? {
        guard let position = checkpoint?.position else { return nil }
        return position.readiumLocatorJSON
            ?? checkpoint.flatMap {
                EpubLocationBridge.readiumLocator(
                    from: position,
                    sourceEngine: $0.sourceEngine
                )
            }
    }

    var checkpointObservedAt: Date? {
        checkpoint.map { Date(timeIntervalSince1970: Double($0.observedAtMs) / 1_000) }
    }

    var restoreTargetLocatorJSON: String? {
        restoreTarget.flatMap { EpubLocationBridge.readiumLocator(from: $0) }
    }

    func setRestoreTarget(locatorJSON: String?, fallbackProgression: Double?) {
        guard let locatorJSON else {
            restoreTarget = nil
            return
        }
        guard
            let position = EpubBridgePosition(
                readiumLocatorJSON: locatorJSON,
                fallbackProgression: fallbackProgression
            )
        else {
            restoreTarget = nil
            return
        }
        restoreTarget = position
    }

    @discardableResult
    func confirmRestore(observedLocatorJSON: String?, fallbackProgression: Double?) -> Bool {
        guard phase == .restoring else { return phase == .active }
        if let restoreTarget {
            guard let observedLocatorJSON,
                let observed = EpubBridgePosition(
                    readiumLocatorJSON: observedLocatorJSON,
                    fallbackProgression: fallbackProgression
                ),
                observed.sharesSemanticLocation(with: restoreTarget)
            else {
                return false
            }
        }
        phase = .active
        restoreTarget = nil
        return true
    }

    @discardableResult
    func confirmPortableRestore(
        observedLocatorJSON: String?,
        fallbackProgression: Double?
    ) -> Bool {
        guard phase == .restoring else { return phase == .active }
        guard let restoreTarget else {
            phase = .active
            return true
        }
        guard restoreTarget.hasPortableAnchor,
            let observedLocatorJSON,
            let observed = EpubBridgePosition(
                readiumLocatorJSON: observedLocatorJSON,
                fallbackProgression: fallbackProgression
            ),
            observed.hasPortableAnchor,
            observed.sharesResource(with: restoreTarget)
        else {
            return false
        }
        phase = .active
        self.restoreTarget = nil
        return true
    }

    func noteUserInteraction() {
        guard phase != .closed else { return }
        userInteractedAfterRestore = true
        if phase == .restoring {
            restoreTarget = nil
        }
    }

    func commit(
        locatorJSON: String,
        fallbackProgression: Double,
        observedAt: Date
    ) throws -> EpubBridgeCheckpoint {
        guard phase == .active else {
            throw EpubBridgeCheckpointError.restoreNotConfirmed
        }
        guard
            let position = EpubBridgePosition(
                readiumLocatorJSON: locatorJSON,
                fallbackProgression: fallbackProgression
            )
        else {
            throw EpubBridgeCheckpointError.invalidLocator
        }
        guard userInteractedAfterRestore else {
            throw EpubBridgeCheckpointError.userInteractionRequired
        }
        let committed = try store.commit(
            position: position,
            lease: lease,
            expectedRevision: expectedRevision,
            observedAt: observedAt,
            allowZero: userInteractedAfterRestore
        )
        expectedRevision = committed.revision
        checkpoint = committed
        userInteractedAfterRestore = false
        return committed
    }

    func close() {
        guard phase != .closed else { return }
        phase = .closed
        store.revoke(lease)
    }
}

enum EpubBridgeBookKey {
    static func make(for book: Book, fileURL: URL? = nil) -> String {
        guard book.source == .silo else {
            return book.stableId
        }
        let downloadedFileID: String? = fileURL.flatMap { url in
            let stem = url.deletingPathExtension().lastPathComponent
            guard let candidate = stem.split(separator: "-").last,
                Int(candidate) != nil
            else { return nil }
            return String(candidate)
        }
        let fileID =
            downloadedFileID
            ?? book.partKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard let fileID else { return book.stableId }
        return "\(book.stableId)#file:\(fileID)"
    }
}

enum EpubPublicationFingerprint {
    nonisolated static func sha256(fileURL: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                try Task.checkCancellation()
                let data = handle.readData(ofLength: 1_048_576)
                guard !data.isEmpty else { break }
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var coalescingWhitespace: String {
        precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
