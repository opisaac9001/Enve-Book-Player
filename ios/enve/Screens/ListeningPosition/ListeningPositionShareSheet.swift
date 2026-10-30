#if os(iOS)
import SwiftUI
import UIKit

struct ListeningPositionShareSheet: View {
    let book: Book

    @Environment(\.profileSession) private var capturedSession
    @Environment(\.hearth) private var hearth

    @State private var payload: ListeningPositionPayload?
    @State private var code: UIImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Overline("Share book position")
                    .padding(.top, 28)

                if let payload, let code {
                    ListeningPositionSharedSummary(payload: payload)

                    Image(uiImage: code)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 300)
                        // Scanners need dark modules on a light quiet zone regardless of the theme.
                        .padding(18)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Book-position code for \(payload.title) at \(ListeningPositionText.position(payload))")

                    Text("In Enve, they open Library, choose More, then Scan book position. The code holds only this book's details and position.")
                        .font(.hearthUI(13))
                        .foregroundStyle(hearth.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        ShareLink(
                            item: Image(uiImage: code),
                            preview: SharePreview(payload.title, image: Image(uiImage: code))
                        ) {
                            Label("Share image", systemImage: "square.and.arrow.up")
                                .font(.hearthUI(15, weight: .medium))
                                .foregroundStyle(hearth.text)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                                .frame(minHeight: 48)
                                .background {
                                    HearthChromeBackground(shape: .capsule, fill: hearth.bgElevated, stroke: hearth.hairline, tint: hearth.bgElevated)
                                }
                        }
                        .buttonStyle(PressableStyle())
                        QuietButton(title: "Update position", systemImage: "arrow.clockwise") {
                            Task { await capture() }
                        }
                    }
                } else {
                    HearthEmpty(
                        glyph: "qrcode",
                        title: "Can't share this position",
                        line: "Enve needs a saved reading position or the audio's length. Positions that exceed the QR size limit can't be shared."
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .task { await capture() }
    }

    private func capture() async {
        let session = capturedSession ?? .owner
        let stored = freshestEbookProgressBook(
            captured: await session.bookStore.book(uniqueId: book.uniqueId) ?? book,
            cached: session.appState.bookInMemory(uniqueId: book.uniqueId)
        )
        let snapshot = session.playback.composition.controller.snapshot
        let liveBook = snapshot.currentBook?.uniqueId == book.uniqueId ? snapshot.currentBook : nil
        let source = stored.mediaType == .ebook ? stored : liveBook ?? stored
        let position = liveBook != nil ? snapshot.position : stored.currentTime
        let duration = (source.duration ?? 0) > 0 ? source.duration ?? 0 : (liveBook != nil ? snapshot.duration : 0)
        payload = source.mediaType == .ebook
            ? ListeningPositionPayload(book: source)
            : ListeningPositionPayload(book: source, position: position, duration: duration)
        code = payload.flatMap { ListeningPositionQRCode.image(for: $0.encoded()) }
    }
}
#endif
