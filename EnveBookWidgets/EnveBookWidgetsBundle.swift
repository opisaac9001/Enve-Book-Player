import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

@main
struct EnveBookWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ContinueListeningWidget()
        BookLockScreenWidget()
        BookTTSLiveActivity()
    }
}

struct BookTTSLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BookTTSActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "text.book.closed.fill")
                    .font(.title3)
                    .foregroundStyle(Color(red: 245 / 255, green: 146 / 255, blue: 26 / 255))
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 2) {
                    Text("READ ALOUD")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                    Text(context.attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(context.attributes.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button(intent: BookPlaybackIntent(command: "tts.toggle")) {
                    Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle().fill(Color(red: 245 / 255, green: 146 / 255, blue: 26 / 255))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(context.state.isPlaying ? "Pause read aloud" : "Resume read aloud")
            }
            .padding(.horizontal, 16)
            .activityBackgroundTint(.black.opacity(0.86))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "text.book.closed.fill")
                        .foregroundStyle(Color(red: 245 / 255, green: 146 / 255, blue: 26 / 255))
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        Text(context.attributes.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.attributes.author)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: BookPlaybackIntent(command: "tts.toggle")) {
                        Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .foregroundStyle(Color(red: 245 / 255, green: 146 / 255, blue: 26 / 255))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(context.state.isPlaying ? "Pause read aloud" : "Resume read aloud")
                }
            } compactLeading: {
                Image(systemName: "text.book.closed.fill")
                    .foregroundStyle(Color(red: 245 / 255, green: 146 / 255, blue: 26 / 255))
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .foregroundStyle(Color(red: 245 / 255, green: 146 / 255, blue: 26 / 255))
            } minimal: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .foregroundStyle(Color(red: 245 / 255, green: 146 / 255, blue: 26 / 255))
            }
            .keylineTint(Color(red: 245 / 255, green: 146 / 255, blue: 26 / 255))
        }
    }
}

struct BookPlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Enve Book Playback"

    @Parameter(title: "Command") var command: String

    init() {}
    init(command: String) { self.command = command }

    func perform() async throws -> some IntentResult {
        await BookWidgetShared.postCommand(command)
        return .result()
    }
}

private struct BookWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: BookWidgetSnapshot
    let artwork: UIImage?
}

private struct BookWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> BookWidgetEntry {
        BookWidgetEntry(
            date: .now,
            snapshot: BookWidgetSnapshot(
                id: "preview",
                title: "The Story Continues",
                author: "Your Library",
                chapter: "Chapter Twelve",
                isPlaying: false,
                hasBook: true,
                elapsed: 3_842,
                duration: 12_405,
                skipBackward: 15,
                skipForward: 30
            ),
            artwork: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (BookWidgetEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BookWidgetEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .never))
    }

    private func entry() -> BookWidgetEntry {
        let artwork = BookWidgetShared.artworkFileURL.flatMap { UIImage(contentsOfFile: $0.path) }
        return BookWidgetEntry(date: .now, snapshot: BookWidgetShared.loadSnapshot(), artwork: artwork)
    }
}

private func timeLabel(_ seconds: TimeInterval) -> String {
    let value = max(0, Int(seconds.rounded()))
    let hours = value / 3_600
    let minutes = (value % 3_600) / 60
    let remainder = value % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
        : String(format: "%d:%02d", minutes, remainder)
}

private struct BookArtwork: View {
    let image: UIImage?
    let palette: HearthWidgetPalette

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    palette.elevated
                    Image(systemName: "books.vertical.fill")
                        .font(.title2)
                        .foregroundStyle(palette.ember)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.hairline, lineWidth: 1)
        }
    }
}

private struct BookProgressBar: View {
    let progress: Double
    let palette: HearthWidgetPalette
    var lightTrack = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(lightTrack ? .white.opacity(0.3) : palette.elevated)
                Capsule()
                    .fill(palette.ember)
                    .frame(width: max(4, geometry.size.width * progress))
            }
        }
        .frame(height: 4)
        .accessibilityValue(Text("\(Int(progress * 100)) percent"))
    }
}

private struct TransportControls: View {
    let snapshot: BookWidgetSnapshot
    let palette: HearthWidgetPalette
    var onArtwork = false

    var body: some View {
        HStack(spacing: 6) {
            transportButton(
                command: "backward",
                symbol: "gobackward.\(snapshot.skipBackward)",
                label: "Skip back \(snapshot.skipBackward) seconds"
            )
            Button(intent: BookPlaybackIntent(command: "toggle")) {
                Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(palette.onEmber)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(palette.ember))
            }
            .accessibilityLabel(snapshot.isPlaying ? "Pause" : "Play")
            transportButton(
                command: "forward",
                symbol: "goforward.\(snapshot.skipForward)",
                label: "Skip forward \(snapshot.skipForward) seconds"
            )
        }
        .buttonStyle(.plain)
    }

    private func transportButton(command: String, symbol: String, label: String) -> some View {
        Button(intent: BookPlaybackIntent(command: command)) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(onArtwork ? .white : palette.text)
                .frame(width: 32, height: 32)
                .background(Circle().fill(onArtwork ? .black.opacity(0.5) : palette.elevated))
        }
        .accessibilityLabel(label)
    }
}

struct ContinueListeningWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: BookWidgetShared.continueKind, provider: BookWidgetProvider()) { entry in
            ContinueListeningView(entry: entry)
        }
        .configurationDisplayName("Continue Listening")
        .description("Your current book, progress, and playback controls.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct ContinueListeningView: View {
    let entry: BookWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    private var palette: HearthWidgetPalette { .resolve(colorScheme) }

    var body: some View {
        if !entry.snapshot.hasBook {
            empty
        } else if family == .systemSmall {
            small
        } else {
            medium
        }
    }

    private var small: some View {
        ZStack(alignment: .bottomLeading) {
            if let artwork = entry.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .overlay {
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.82)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
            } else {
                palette.background
            }

            VStack(alignment: .leading, spacing: 5) {
                Spacer(minLength: 42)
                Text(entry.snapshot.title)
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundStyle(entry.artwork == nil ? palette.text : .white)
                    .lineLimit(2)
                BookProgressBar(
                    progress: entry.snapshot.progress,
                    palette: palette,
                    lightTrack: entry.artwork != nil
                )
                HStack {
                    Text(timeLabel(entry.snapshot.elapsed))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(entry.artwork == nil ? palette.secondary : .white.opacity(0.78))
                    Spacer(minLength: 2)
                    Button(intent: BookPlaybackIntent(command: "toggle")) {
                        Image(systemName: entry.snapshot.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(palette.onEmber)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(palette.ember))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(entry.snapshot.isPlaying ? "Pause" : "Play")
                }
            }
            .padding(14)
        }
        .containerBackground(palette.background, for: .widget)
    }

    private var medium: some View {
        HStack(spacing: 14) {
            BookArtwork(image: entry.artwork, palette: palette)
                .aspectRatio(0.72, contentMode: .fit)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 3) {
                Text("CONTINUE LISTENING")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(palette.ember)
                Text(entry.snapshot.title)
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Text(entry.snapshot.chapter.isEmpty ? entry.snapshot.author : entry.snapshot.chapter)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)
                BookProgressBar(progress: entry.snapshot.progress, palette: palette)
                HStack {
                    Text(timeLabel(entry.snapshot.elapsed))
                    Spacer()
                    Text(timeLabel(entry.snapshot.duration))
                }
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(palette.secondary)

                HStack {
                    Spacer(minLength: 0)
                    TransportControls(snapshot: entry.snapshot, palette: palette)
                    Spacer(minLength: 0)
                }
            }
        }
        .containerBackground(palette.background, for: .widget)
    }

    private var empty: some View {
        VStack(spacing: 7) {
            Image(systemName: "books.vertical.fill")
                .font(.title2)
                .foregroundStyle(palette.ember)
            Text("Your next chapter awaits.")
                .font(.system(size: 14, weight: .semibold, design: .serif))
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.text)
            if family == .systemMedium {
                Text("Start a book in Enve to keep it close.")
                    .font(.caption2)
                    .foregroundStyle(palette.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(palette.background, for: .widget)
    }
}

struct BookLockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: BookWidgetShared.lockScreenKind, provider: BookWidgetProvider()) { entry in
            BookLockScreenView(entry: entry)
        }
        .configurationDisplayName("Book Progress")
        .description("Keep your current chapter and progress on the Lock Screen.")
        .supportedFamilies([.accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}

private struct BookLockScreenView: View {
    let entry: BookWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            rectangular
        default:
            inline
        }
    }

    private var inline: some View {
        Label {
            Text(
                entry.snapshot.hasBook
                    ? "\(entry.snapshot.title) · \(Int(entry.snapshot.progress * 100))%"
                    : "Choose your next book"
            )
        } icon: {
            Image(systemName: entry.snapshot.isPlaying ? "book.fill" : "bookmark.fill")
        }
    }

    private var circular: some View {
        Gauge(value: entry.snapshot.progress) {
            Image(systemName: entry.snapshot.isPlaying ? "waveform" : "book.closed.fill")
        } currentValueLabel: {
            Text("\(Int(entry.snapshot.progress * 100))")
                .font(.system(size: 15, weight: .bold).monospacedDigit())
        }
        .gaugeStyle(.accessoryCircular)
        .widgetAccentable()
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: entry.snapshot.isPlaying ? "waveform" : "book.closed.fill")
                    .widgetAccentable()
                Text(entry.snapshot.hasBook ? entry.snapshot.title : "Enve Book Player")
                    .font(.headline)
                    .lineLimit(1)
            }
            if entry.snapshot.hasBook {
                ProgressView(value: entry.snapshot.progress)
                    .tint(.primary)
                HStack {
                    Text(timeLabel(entry.snapshot.elapsed))
                    Spacer()
                    Text(timeLabel(entry.snapshot.duration))
                }
                .font(.system(size: 9, weight: .medium).monospacedDigit())
            } else {
                Text("Your next chapter awaits.")
                    .font(.caption)
            }
        }
    }
}
