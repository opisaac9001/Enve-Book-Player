#if os(iOS)
import SwiftUI

struct ClubDiscussionLinkScreen: View {
    let store: ClubsStore
    let session: ProfileSession
    let account: ClubAccount
    let link: ClubDiscussionLink
    let closeClubs: () -> Void

    @State private var context: Context?
    @State private var error: String?

    private struct Context {
        let club: ClubDetails
        let read: ClubReadDetails
        let checkpoint: ClubCheckpoint?
    }

    var body: some View {
        if let context {
            let book = store.copy(for: link.readID).flatMap { session.appState.bookInMemory(uniqueId: $0.bookID) }
            ClubThreadScreen(store: store, session: session, account: account, club: context.club, details: context.read,
                             checkpoint: context.checkpoint, book: book, focusPostID: link.postID, closeClubs: closeClubs)
        } else {
            ClubPage {
                if let error {
                    ClubErrorLine(message: error)
                    Button("Try Again") { Task { await load() } }
                } else {
                    ProgressView().accessibilityLabel("Loading discussion")
                }
            }
            .navigationTitle("Discussion")
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
        }
    }

    private func load() async {
        error = nil
        do {
            let base = "clubs/\(link.clubID)"
            let club: ClubDetails = try await store.request(base)
            let read: ClubReadDetails = try await store.request(base + "/reads/" + link.readID)
            let checkpoint = read.checkpoints.first { $0.id == link.threadID }
            if link.threadID != "general", checkpoint == nil {
                error = "This discussion is no longer available."
                return
            }
            context = Context(club: club, read: read, checkpoint: checkpoint)
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}
#endif
