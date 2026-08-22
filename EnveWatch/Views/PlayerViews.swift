import Combine
import SwiftUI
import WatchKit

struct LocalPlayerView: View {
    @State private var player = WatchPlayerModel.shared
    @State private var showChapters = false
    @State private var showSpeed = false
    @State private var showSleep = false

    var body: some View {
        VStack(spacing: 6) {
            if let descriptor = player.descriptor {
                Text(player.currentChapter?.title ?? descriptor.title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)

                ProgressView(value: player.duration > 0 ? min(player.position / player.duration, 1) : 0)
                    .tint(WatchTheme.ember)

                HStack {
                    Text(WatchTheme.timeString(player.position))
                    Spacer()
                    Text(WatchTheme.remainingString(position: player.position, duration: player.duration))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                TransportControls(
                    isPlaying: player.isPlaying,
                    isLoading: player.isLoading,
                    onBackward: { player.skipBackward() },
                    onToggle: { player.togglePlay() },
                    onForward: { player.skipForward() }
                )

                HStack(spacing: 14) {
                    Button {
                        showChapters = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .buttonStyle(.plain)
                    .disabled(player.chapters.isEmpty)

                    Button {
                        showSpeed = true
                    } label: {
                        Text(String(format: "%.2g×", player.speed))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)

                    Button {
                        showSleep = true
                    } label: {
                        Image(systemName: player.sleepRemaining > 0 || player.sleepUntilChapterEnd ? "moon.fill" : "moon")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(player.sleepRemaining > 0 || player.sleepUntilChapterEnd ? WatchTheme.ember : .primary)
                }
                .font(.system(size: 15))

                if let error = player.playbackError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            } else {
                ContentUnavailableView("Nothing playing", systemImage: "headphones")
            }
        }
        .padding(.horizontal, 4)
        .navigationTitle("Player")
        .background(WatchVolumeCapture(origin: .local).opacity(0))
        .sheet(isPresented: $showChapters) {
            ChapterListSheet()
        }
        .sheet(isPresented: $showSpeed) {
            SpeedSheet(current: player.speed) { player.speed = $0 }
        }
        .sheet(isPresented: $showSleep) {
            SleepSheet(
                remaining: player.sleepRemaining,
                untilChapterEnd: player.sleepUntilChapterEnd,
                onMinutes: { player.startSleepTimer(minutes: $0) },
                onChapterEnd: { player.startSleepTimerToChapterEnd() },
                onCancel: { player.cancelSleepTimer() }
            )
        }
    }
}

struct RemotePlayerView: View {
    private static func skipSymbol(base: String, seconds: Int) -> String {
        [5, 10, 15, 30, 45, 60, 75, 90].contains(seconds) ? "\(base).\(seconds)" : base
    }

    @State private var link = PhoneLink.shared
    @State private var showSpeed = false
    @State private var showSleep = false
    @State private var displayPosition: TimeInterval = 0

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let state = link.nowPlaying
        VStack(spacing: 6) {
            if state.hasBook {
                Text(state.chapterTitle.isEmpty ? state.title : state.chapterTitle)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)

                ProgressView(value: state.duration > 0 ? min(displayPosition / state.duration, 1) : 0)
                    .tint(WatchTheme.ember)

                HStack {
                    Text(WatchTheme.timeString(displayPosition))
                    Spacer()
                    Text(WatchTheme.remainingString(position: displayPosition, duration: state.duration))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                TransportControls(
                    isPlaying: link.nowPlayingIsLive,
                    isLoading: false,
                    backwardSymbol: Self.skipSymbol(base: "gobackward", seconds: state.skipBackward),
                    forwardSymbol: Self.skipSymbol(base: "goforward", seconds: state.skipForward),
                    onBackward: { link.sendCommand(WatchCommandPayload(action: .skipBackward)) },
                    onToggle: { link.sendCommand(WatchCommandPayload(action: .toggle)) },
                    onForward: { link.sendCommand(WatchCommandPayload(action: .skipForward)) }
                )

                HStack(spacing: 14) {
                    Image(systemName: "iphone")
                        .foregroundStyle(.secondary)
                    Button {
                        showSpeed = true
                    } label: {
                        Text(String(format: "%.2g×", state.speed))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    Button {
                        showSleep = true
                    } label: {
                        Image(systemName: (state.sleepRemaining ?? 0) > 0 ? "moon.fill" : "moon")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle((state.sleepRemaining ?? 0) > 0 ? WatchTheme.ember : .primary)
                }
                .font(.system(size: 15))

                if !link.isReachable {
                    Label("iPhone unreachable", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } else {
                ContentUnavailableView("Nothing playing on iPhone", systemImage: "iphone.slash")
            }
        }
        .padding(.horizontal, 4)
        .navigationTitle("iPhone")
        .background(WatchVolumeCapture(origin: .companion).opacity(0))
        .onReceive(ticker) { _ in
            displayPosition = link.remotePosition
        }
        .onAppear {
            displayPosition = link.remotePosition
            link.requestFreshNowPlaying()
        }
        .sheet(isPresented: $showSpeed) {
            SpeedSheet(current: state.speed) { rate in
                link.sendCommand(WatchCommandPayload(action: .speed, seconds: rate))
            }
        }
        .sheet(isPresented: $showSleep) {
            SleepSheet(
                remaining: state.sleepRemaining ?? 0,
                untilChapterEnd: false,
                onMinutes: { link.sendCommand(WatchCommandPayload(action: .sleep, seconds: Double($0))) },
                onChapterEnd: { link.sendCommand(WatchCommandPayload(action: .sleep, seconds: -2)) },
                onCancel: { link.sendCommand(WatchCommandPayload(action: .sleep, seconds: -1)) }
            )
        }
    }
}

private struct TransportControls: View {
    let isPlaying: Bool
    let isLoading: Bool
    var backwardSymbol = "gobackward.15"
    var forwardSymbol = "goforward.30"
    let onBackward: () -> Void
    let onToggle: () -> Void
    let onForward: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onBackward) {
                Image(systemName: backwardSymbol)
                    .font(.system(size: 20, weight: .medium))
            }
            .buttonStyle(.plain)

            Button(action: onToggle) {
                Group {
                    if isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 40))
                    }
                }
                .foregroundStyle(WatchTheme.ember)
            }
            .buttonStyle(.plain)

            Button(action: onForward) {
                Image(systemName: forwardSymbol)
                    .font(.system(size: 20, weight: .medium))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}

struct ChapterListSheet: View {
    @State private var player = WatchPlayerModel.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(player.chapters, id: \.index) { chapter in
            Button {
                player.seekToChapter(chapter)
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chapter.title)
                            .font(.caption2)
                            .lineLimit(2)
                        Text(WatchTheme.timeString(chapter.start))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    if player.currentChapter?.index == chapter.index {
                        Spacer()
                        Image(systemName: "waveform")
                            .font(.caption2)
                            .foregroundStyle(WatchTheme.ember)
                    }
                }
            }
        }
        .navigationTitle("Chapters")
    }
}

struct SpeedSheet: View {
    let current: Double
    let onSelect: (Double) -> Void
    @Environment(\.dismiss) private var dismiss

    private let speeds: [Double] = [0.75, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    var body: some View {
        List(speeds, id: \.self) { speed in
            Button {
                onSelect(speed)
                dismiss()
            } label: {
                HStack {
                    Text(String(format: "%.2g×", speed))
                    if abs(speed - current) < 0.01 {
                        Spacer()
                        Image(systemName: "checkmark")
                            .foregroundStyle(WatchTheme.ember)
                    }
                }
            }
        }
        .navigationTitle("Speed")
    }
}

struct SleepSheet: View {
    let remaining: TimeInterval
    let untilChapterEnd: Bool
    let onMinutes: (Int) -> Void
    let onChapterEnd: () -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let options = [5, 10, 15, 30, 45, 60]

    var body: some View {
        List {
            if remaining > 0 || untilChapterEnd {
                Section {
                    Text(untilChapterEnd ? "Until chapter ends" : "\(Int(remaining / 60) + 1) min left")
                        .font(.caption2)
                        .foregroundStyle(WatchTheme.ember)
                    Button("Turn Off") {
                        onCancel()
                        dismiss()
                    }
                }
            }
            Section {
                ForEach(options, id: \.self) { minutes in
                    Button("\(minutes) minutes") {
                        onMinutes(minutes)
                        dismiss()
                    }
                }
                Button("End of Chapter") {
                    onChapterEnd()
                    dismiss()
                }
            }
        }
        .navigationTitle("Sleep Timer")
    }
}

struct WatchVolumeCapture: WKInterfaceObjectRepresentable {
    let origin: WKInterfaceVolumeControl.Origin

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        let control = WKInterfaceVolumeControl(origin: origin)
        control.focus()
        return control
    }

    func updateWKInterfaceObject(_ wkInterfaceObject: WKInterfaceVolumeControl, context: Context) {
        wkInterfaceObject.focus()
    }
}
