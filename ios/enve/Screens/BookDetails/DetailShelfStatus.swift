import Combine
import SwiftUI

@Observable
final class DetailShelfStatus {
    private(set) var current: BookOrbitProvider.BookOrbitReadStatus?
    private(set) var message: String?
    private(set) var failed = false
    private(set) var isUpdating = false

    func load(book: Book, library: LibraryEngine, profileSession: ProfileSession = .owner) async {
        guard book.source == .bookOrbit,
            let provider = library.provider(for: book) as? BookOrbitProvider
        else { return }
        current = await provider.fetchReadStatus(for: book)
    }

    func set(_ status: BookOrbitProvider.BookOrbitReadStatus, book: Book, library: LibraryEngine, profileSession: ProfileSession = .owner) async {
        let edits = profileSession.bookEdits
        guard library.provider(for: book) is BookOrbitProvider,
            edits.submit(.readStatus(status.rawValue), for: book) != nil
        else {
            failed = true
            message = "BookOrbit isn't connected on this device"
            return
        }

        isUpdating = true
        failed = false
        message = nil
        defer { isUpdating = false }

        let confirmation: String
        let now = Date()
        var updated = book
        func updateLocal(_ change: (inout Book) -> Void) { change(&updated) }

        switch status {
        case .read:
            updateLocal {
                $0.isFinished = true
                $0.hideFromContinue = true
                $0.serverReadStatus = status.rawValue.uppercased()
                $0.lastUpdate = now
                if $0.mediaType == .ebook {
                    $0.ebookProgress = max($0.ebookProgress ?? 0, 1.0)
                } else if let duration = $0.duration, duration > 0 {
                    $0.currentTime = duration
                }
            }
            profileSession.bookProgress.remove(stableId: book.stableId)
            confirmation = "Shelved as finished on BookOrbit"
        case .abandoned:
            updateLocal {
                $0.isFinished = false
                $0.hideFromContinue = true
                $0.serverReadStatus = status.rawValue.uppercased()
                $0.lastUpdate = now
            }
            profileSession.bookProgress.remove(stableId: book.stableId)
            confirmation = "Set aside on BookOrbit"
        case .reading, .rereading:
            updateLocal {
                $0.isFinished = false
                $0.hideFromContinue = false
                $0.serverReadStatus = status.rawValue.uppercased()
                $0.lastUpdate = now
            }
            confirmation = status == .rereading ? "Reading again, says BookOrbit" : "Back on the reading shelf"
        case .wantToRead, .onHold:
            updateLocal {
                $0.isFinished = false
                $0.hideFromContinue = true
                $0.serverReadStatus = status.rawValue.uppercased()
                $0.lastUpdate = now
            }
            profileSession.bookProgress.remove(stableId: book.stableId)
            confirmation = status == .onHold ? "Resting on hold on BookOrbit" : "Shelved as want to read"
        case .skimmed:
            updateLocal {
                $0.isFinished = true
                $0.hideFromContinue = true
                $0.serverReadStatus = status.rawValue.uppercased()
                $0.lastUpdate = now
            }
            profileSession.bookProgress.remove(stableId: book.stableId)
            confirmation = "Shelved as skimmed on BookOrbit"
        case .unread:
            updateLocal {
                $0.currentTime = 0
                $0.ebookProgress = $0.mediaType == .ebook ? 0 : nil
                $0.epubLocator = nil
                $0.isFinished = false
                $0.hideFromContinue = false
                $0.serverReadStatus = status.rawValue.uppercased()
                $0.lastUpdate = now
            }
            profileSession.bookProgress.remove(stableId: book.stableId)
            confirmation = "Shelved as unread on BookOrbit"
        }

        if library.updateBook(uniqueId: book.uniqueId, { $0 = updated }) == nil {
            await profileSession.bookStore.upsertBooks([updated])
        }
        current = status
        library.notifyLibraryChanged()
        NotificationCenter.default.post(name: .continueListeningNeedsRefresh, object: nil)

        await edits.flush()
        // The queued edit carries its own waiting or failure state; only a delivered one is confirmed here.
        if edits.pendingEdit(for: book, kind: .readStatus) == nil {
            message = confirmation
        }
    }
}

struct DetailPendingEditNote: View {
    let book: Book
    let kind: PendingBookEditKind
    let serverName: String
    var onDiscard: () -> Void = {}

    @Environment(\.profileSession) private var capturedSession
    @Environment(\.hearth) private var hearth
    @State private var retrying = false

    private var edits: PendingBookEditQueue { (capturedSession ?? .owner).bookEdits }
    private var identifier: String { "detail-pending-\(kind.rawValue)" }

    var body: some View {
        if let status = edits.status(for: book, kind: kind) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: glyph(status))
                    .font(.hearthUI(13, weight: .semibold))
                    .foregroundStyle(isError(status) ? hearth.statusError : hearth.textTertiary)
                    .accessibilityHidden(true)
                Text(text(status))
                    .font(.hearthUI(13))
                    .foregroundStyle(isError(status) ? hearth.statusError : hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(identifier)-status")
                Spacer(minLength: 8)
                if status != .sending {
                    Button("Retry") {
                        retrying = true
                        Task {
                            await edits.retry(book, kind: kind)
                            retrying = false
                        }
                    }
                    .disabled(retrying)
                    .accessibilityIdentifier("\(identifier)-retry")
                }
                if case .rejected = status {
                    Button("Discard", role: .destructive) {
                        if edits.discard(book, kind: kind) { onDiscard() }
                    }
                    .accessibilityIdentifier("\(identifier)-discard")
                }
            }
            .font(.hearthUI(13, weight: .medium))
            .tint(hearth.ember)
            .frame(minHeight: 44)
            .accessibilityElement(children: .contain)
        }
    }

    private func isError(_ status: PendingBookEditStatus) -> Bool {
        switch status {
        case .needsSignIn, .rejected: true
        case .sending, .waiting, .retrying: false
        }
    }

    private func glyph(_ status: PendingBookEditStatus) -> String {
        switch status {
        case .sending: "arrow.triangle.2.circlepath"
        case .waiting, .retrying: "clock"
        case .needsSignIn: "person.crop.circle.badge.exclamationmark"
        case .rejected: "exclamationmark.triangle"
        }
    }

    private func text(_ status: PendingBookEditStatus) -> String {
        let subject = kind == .rating ? "Rating" : "Reading status"
        switch status {
        case .sending: return "Sending \(subject.lowercased()) to \(serverName)…"
        case .waiting: return "\(subject) saved on this device. Waiting to sync with \(serverName)."
        case .retrying(let message): return "\(subject) saved on this device. Waiting to sync: \(message)"
        case .needsSignIn: return "\(subject) saved on this device. Sign in to \(serverName) again to sync it."
        case .rejected(let message): return "\(subject) not synced. \(message)"
        }
    }
}
