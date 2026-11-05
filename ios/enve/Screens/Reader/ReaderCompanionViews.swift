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

/// One action a Listen Along state offers, such as Back to narration or Try again.
struct ReaderListenAlongAction {
    let title: String
    let systemImage: String
    let run: () -> Void
}

/// The linked audiobook in the reader chrome: Listen Along for an ordinary EPUB, otherwise the plain audio button.
struct ReaderListenAlongBar: View {
    let audiobook: Book
    let playback: any PlaybackControlling
    @ObservedObject var model: ClassicReaderModel
    let statusAction: ReaderListenAlongAction?
    let onSettings: () -> Void
    let onListenFromPage: () -> Void

    @Environment(\.hearth) private var hearth
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var narration = ReaderListenAlongNarration()

    var body: some View {
        Group {
            if model.isLinkedReadAlongAvailable, model.isLinkedReadAlongRequested {
                panel
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { entry }
                    VStack(spacing: 8) { entry }
                }
            }
        }
        .onAppear { narration.observe(playback.snapshot, audiobook: audiobook) }
        .onReceive(playback.snapshots) { narration.observe($0, audiobook: audiobook) }
    }

    @ViewBuilder
    private var entry: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(hearth.statusOK)
                .frame(width: 6, height: 6)
            Text("Linked")
                .font(.hearthUI(11, weight: .semibold))
                .foregroundStyle(hearth.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audiobook linked")
        if model.isLinkedReadAlongAvailable {
            Button {
                PlatformHaptics.selection()
                model.toggleLinkedReadAlong()
            } label: {
                capsule(systemImage: "headphones", title: "Listen Along")
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Listen Along")
            .accessibilityValue("Off")
            .accessibilityHint("Plays the linked audiobook with this book, highlighting what is narrated")
            .accessibilityIdentifier("reader.readAlong.toggle")
        } else {
            let label = narration.isPlaying ? "Pause Listen Along" : (narration.isCurrent ? "Resume Listen Along" : "Listen along")
            Button {
                model.toggleLinkedListening(audiobook: audiobook)
            } label: {
                capsule(systemImage: narration.isPlaying ? "pause.fill" : "headphones", title: dynamicTypeSize.isAccessibilitySize ? (narration.isPlaying ? "Pause" : "Listen") : label)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(label)
            .accessibilityHint("Plays the linked audiobook in step with your reading position")
            .accessibilityIdentifier("reader.listenAlong.transport")
        }
    }

    private var panel: some View {
        VStack(spacing: 8) {
            ReaderNarrationBar(
                source: "Listen Along",
                identifier: "Reader.ListenAlong",
                isPlaying: narration.isPlaying,
                isLoaded: narration.isLoaded,
                rate: narration.rate,
                timeline: { [playback, audiobook] in
                    let snapshot = playback.snapshot
                    guard snapshot.currentBook?.stableId == audiobook.stableId else {
                        return ReaderNarrationTimeline(elapsed: 0, duration: 0)
                    }
                    return ReaderNarrationTimeline(elapsed: snapshot.position, duration: snapshot.duration)
                },
                onTogglePlayback: { model.toggleLinkedNarrationPlayback() },
                onSkipBackward: { model.skipLinkedNarration(by: -15) },
                onSkipForward: { model.skipLinkedNarration(by: 30) },
                onSeek: { model.seekLinkedNarration(to: $0) },
                onRate: { model.setLinkedNarrationRate($0) },
                onSettings: onSettings,
                onStop: { model.stopListenAlong() }
            ) {
                ReaderNarrationIconButton(
                    systemImage: "text.line.first.and.arrowtriangle.forward",
                    label: "Listen from this page",
                    action: onListenFromPage
                )
            } speedOptions: {}
            statusRow(ReaderReadAlongStatus.message(for: model.linkedReadAlongStatus))
        }
    }

    private func capsule(systemImage: String, title: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.hearthUI(13, weight: .semibold))
            Text(title)
                .font(.hearthUI(14, weight: .medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(hearth.text)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
        .contentShape(Capsule())
        .background {
            HearthChromeBackground(shape: .capsule, fill: hearth.bgElevated, stroke: hearth.hairline, tint: hearth.bgElevated)
        }
    }

    private func statusRow(_ message: String?) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 8))
        return VStack(spacing: 2) {
            layout {
                if let message {
                    Text(message)
                        .font(.hearthUI(13, weight: .medium))
                        .foregroundStyle(hearth.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let statusAction {
                    Button {
                        PlatformHaptics.selection()
                        statusAction.run()
                    } label: {
                        Label(statusAction.title, systemImage: statusAction.systemImage)
                            .font(.hearthUI(13, weight: .semibold))
                            .foregroundStyle(hearth.text)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityIdentifier("reader.readAlong.action")
                }
            }
            Text("Double-tap a line to listen from there")
                .font(.hearthUI(12, weight: .medium))
                .foregroundStyle(hearth.textSecondary.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("reader.listenAlong.hint")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.readAlong.status")
    }
}

/// Listen Along while the reader chrome is hidden.
struct ReaderListenAlongPill: View {
    let playback: any PlaybackControlling
    let audiobook: Book
    @ObservedObject var model: ClassicReaderModel
    let statusAction: ReaderListenAlongAction?
    let onBookmark: () -> Void
    let onShowControls: () -> Void

    @Environment(\.hearth) private var hearth
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var narration = ReaderListenAlongNarration()

    var body: some View {
        VStack(spacing: 8) {
            if model.linkedReadAlongStatus != .following, let message = ReaderReadAlongStatus.message(for: model.linkedReadAlongStatus) {
                HStack(spacing: 4) {
                    Text(message)
                        .font(.hearthUI(13, weight: .semibold))
                        .foregroundStyle(hearth.textSecondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                        .padding(.vertical, 8)
                    if let statusAction {
                        Button {
                            PlatformHaptics.selection()
                            statusAction.run()
                        } label: {
                            Label(statusAction.title, systemImage: statusAction.systemImage)
                                .font(.hearthUI(13, weight: .semibold))
                                .foregroundStyle(hearth.text)
                                .padding(.horizontal, 8)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityIdentifier("reader.readAlong.action")
                    }
                }
                .padding(.horizontal, 16)
                .background {
                    HearthChromeBackground(shape: .capsule, fill: hearth.bgElevated, stroke: hearth.hairline, tint: hearth.bgElevated, shadow: true)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("reader.readAlongPill")
            }
            ReaderNarrationCapsule(identifier: "reader-listen-along-controls") {
                ReaderNarrationPillButton(systemImage: "gobackward.15", label: "Rewind Listen Along 15 seconds") {
                    model.skipLinkedNarration(by: -15)
                }
                .disabled(!narration.isLoaded)
                .opacity(narration.isLoaded ? 1 : 0.4)
                ReaderNarrationPillButton(
                    systemImage: narration.isPlaying ? "pause.fill" : "play.fill",
                    label: narration.isPlaying ? "Pause Listen Along" : "Play Listen Along",
                    primary: true
                ) {
                    model.toggleLinkedNarrationPlayback()
                }
                .accessibilityIdentifier("Reader.ListenAlong.PlayPause")
                ReaderNarrationPillButton(systemImage: "goforward.30", label: "Skip Listen Along 30 seconds") {
                    model.skipLinkedNarration(by: 30)
                }
                .disabled(!narration.isLoaded)
                .opacity(narration.isLoaded ? 1 : 0.4)
                ReaderNarrationPillButton(systemImage: "bookmark", label: "Bookmark this page", action: onBookmark)
                ReaderNarrationPillButton(systemImage: "ellipsis", label: "Show Listen Along controls", action: onShowControls)
            }
        }
        .onAppear { narration.observe(playback.snapshot, audiobook: audiobook) }
        .onReceive(playback.snapshots) { narration.observe($0, audiobook: audiobook) }
    }
}

/// The linked audiobook's transport state, updated only when a shown value changes.
struct ReaderListenAlongNarration: Equatable {
    var isCurrent = false
    var isLoaded = false
    var isPlaying = false
    var rate: Double = 1

    mutating func observe(_ snapshot: PlaybackSnapshot, audiobook: Book) {
        var next = ReaderListenAlongNarration()
        next.isCurrent = snapshot.currentBook?.stableId == audiobook.stableId
        if next.isCurrent {
            next.isLoaded = snapshot.isLoaded
            next.isPlaying = snapshot.isPlaying
            next.rate = snapshot.playbackSpeed
        }
        if next != self { self = next }
    }
}

enum ReaderReadAlongStatus {
    static func message(for status: ReaderLinkedReadAlongController.Status) -> String? {
        switch status {
        case .idle: nil
        case .following: "Listening along"
        case .browsing: "Reading on while narration continues"
        case .preparing(.starting): "Preparing this passage"
        case .preparing(.identifyingFiles): "Identifying the audiobook files"
        case .preparing(.loadingEngine): "Loading the alignment engine and book text"
        case .preparing(.waitingForPassage): "Waiting to match this passage"
        case .preparing(.matchingPassage): "Matching this passage"
        case .narrationElsewhere: "The linked audiobook isn't playing"
        case .blocked(let reason): reason.message
        case .unmatched(.analysisFailed): "Matching this passage failed."
        case .unmatched(.noConfidentMatch): "No confident match for this passage."
        case .passagesOff: "Prepared passages are turned off in StoryAlign settings."
        case .unavailable(let reason): reason
        }
    }
}
