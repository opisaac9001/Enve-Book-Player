import SwiftUI

struct MiniPlayer_tvOS: View {
    @Environment(PlayerViewModel.self) private var playerVM
    let onTap: () -> Void

    var body: some View {
        if let book = playerVM.currentBook {
            Button(action: onTap) {
                HStack(spacing: 20) {
                    coverThumbnail(for: book)
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(book.title)
                            .font(.headline)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        if let chapter = playerVM.currentChapter {
                            Text(chapter.title)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if let author = book.author {
                            Text(author)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    progressIndicator
                        .frame(width: 220)

                    Image(systemName: playerVM.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 56, height: 56)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 60)
                .padding(.bottom, 12)
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var progressIndicator: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)
                .tint(.white)
            HStack {
                Text(formatTime(playerVM.progress))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Text("-\(formatTime(max(0, playerVM.duration - playerVM.progress)))")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var progressFraction: Double {
        guard playerVM.duration > 0 else { return 0 }
        return max(0, min(1, playerVM.progress / playerVM.duration))
    }

    private func coverThumbnail(for book: Book) -> some View {
        Group {
            if let url = book.coverURL {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.secondary.opacity(0.3)
                }
            } else {
                Color.secondary.opacity(0.3)
                    .overlay(
                        Image(systemName: "headphones")
                            .foregroundStyle(.secondary)
                    )
            }
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

extension View {

    func miniPlayerOverlay() -> some View {
        modifier(MiniPlayerOverlay_tvOS())
    }
}

struct MiniPlayerOverlay_tvOS: ViewModifier {
    @Environment(PlayerViewModel.self) private var playerVM
    @State private var isPresentingPlayer = false

    @State private var lastAutoPresentedBookId: String?

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                if playerVM.currentBook != nil {
                    MiniPlayer_tvOS { isPresentingPlayer = true }
                }
            }
            .fullScreenCover(isPresented: $isPresentingPlayer) {
                NavigationStack { PlayerView_tvOS() }
            }
            .onChange(of: playerVM.currentBook?.stableId) { _, newId in
                guard let newId, newId != lastAutoPresentedBookId else { return }
                lastAutoPresentedBookId = newId

                if !playerVM.currentBookWasRestored {
                    isPresentingPlayer = true
                }
            }
    }
}
