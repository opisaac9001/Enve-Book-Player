import Combine
import SwiftUI

struct ReaderTogetherBanner: View {
    let onStop: () -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        let connected = CompanionBroadcasterService.shared.isReceiverConnected
        HStack(spacing: 12) {
            Image(systemName: connected ? "appletv.fill" : "appletv")
                .font(.hearthUI(15, weight: .semibold))
                .foregroundStyle(connected ? hearth.ember : hearth.statusWarn)

            VStack(alignment: .leading, spacing: 1) {
                Text(connected ? "Reading on Apple TV" : "Waiting for the Apple TV…")
                    .font(.hearthUI(14, weight: .semibold))
                    .foregroundStyle(hearth.text)
                Text(
                    connected
                        ? "Pages mirror here. Keep Enve open."
                        : "Open Read Together on your Apple TV."
                )
                .font(.hearthUI(11))
                .foregroundStyle(hearth.textSecondary)
            }

            Spacer(minLength: 8)

            if !connected {
                ProgressView()
                    .controlSize(.small)
                    .tint(hearth.textSecondary)
            }

            Button(action: onStop) {
                Text("Stop")
                    .font(.hearthUI(13, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Stop reading together")
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .background {
            HearthChromeBackground(
                shape: .rounded(16),
                fill: hearth.bgElevated,
                stroke: hearth.hairline,
                tint: connected ? hearth.ember : hearth.bgElevated,
                shadow: true
            )
        }
        .padding(.horizontal, 16)
    }
}

struct ReaderCastingCover: View {
    @ObservedObject var model: ClassicReaderModel
    let bookTitle: String

    @Environment(\.hearth) private var hearth

    var body: some View {
        ZStack {
            hearth.bg.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "appletv.fill")
                    .font(.hearthUI(54))
                    .foregroundStyle(hearth.ember)
                Text("Casting to Apple TV")
                    .font(.hearthDisplay(24, weight: .semibold))
                    .foregroundStyle(hearth.text)
                Text("\(bookTitle) is showing on your Apple TV. Turn pages with the remote, or from here.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                HStack(spacing: 16) {
                    GlyphButton(systemImage: "chevron.left", size: 56, glyphSize: 19, label: "Previous page") {
                        Task { await model.pageBackward() }
                    }
                    GlyphButton(systemImage: "chevron.right", size: 56, glyphSize: 19, label: "Next page") {
                        Task { await model.pageForward() }
                    }
                }
                .padding(.top, 8)

                QuietButton(title: "Stop casting") {
                    Task { await model.stopReadTogether() }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 32)
        }
    }
}

struct ReaderListenAlongBar: View {
    let ebook: Book
    let audiobook: Book
    @ObservedObject var model: ClassicReaderModel

    @Environment(\.hearth) private var hearth
    private var player: PlayerViewModel { .shared }

    private var isActive: Bool {
        player.currentBook?.stableId == audiobook.stableId
            && player.isPlaying
    }

    private var label: String {
        if isActive { return "Pause Listen Along" }
        if player.currentBook?.stableId == audiobook.stableId {
            return "Resume Listen Along"
        }
        return "Listen along"
    }

    var body: some View {
        Button {
            readerToggleListenAlong()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: isActive ? "pause.fill" : "headphones")
                    .font(.hearthUI(13, weight: .semibold))
                if isActive {
                    Image(systemName: "waveform")
                        .font(.hearthUI(11, weight: .semibold))
                        .symbolEffect(.variableColor.iterative, isActive: true)
                }
                Text(label)
                    .font(.hearthUI(14, weight: .medium))
            }
            .foregroundStyle(isActive ? hearth.onEmber : hearth.text)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background {
                if isActive {
                    HearthChromeBackground(
                        shape: .capsule,
                        fill: hearth.ember,
                        tint: hearth.ember
                    )
                } else {
                    HearthChromeBackground(
                        shape: .capsule,
                        fill: hearth.bgElevated,
                        stroke: hearth.hairline,
                        tint: hearth.bgElevated
                    )
                }
            }
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
        .accessibilityHint("Plays the linked audiobook in step with your reading position")
        .animation(.smooth(duration: 0.25), value: isActive)
    }

    private func readerToggleListenAlong() {
        if player.currentBook?.stableId == audiobook.stableId {
            player.togglePlay()
            return
        }

        let chapterIndex = model.currentChapterIndex ?? 0
        let seekTarget = EbookAudiobookLinker.shared.audiobookTimeForEbookChapter(chapterIndex, ebook: ebook) ?? 0

        model.saveProgress()
        Task { @MainActor in
            EnveEngine.shared.playback.play(audiobook, presentPlayer: false)
            for _ in 0..<20 {
                if player.currentBook?.stableId == audiobook.stableId,
                    !player.isLoading
                {
                    break
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            player.seek(to: seekTarget)
            if !player.isPlaying {
                player.togglePlay()
            }
        }
    }
}
