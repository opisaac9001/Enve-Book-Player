import SwiftUI

enum PlayerScrubScope: String, CaseIterable, Identifiable {
    case book
    case chapter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .book: return "Book"
        case .chapter: return "Chapter"
        }
    }
}

struct PlayerChapterRibbon: View {
    let chapters: [Chapter]
    let duration: TimeInterval
    let currentTime: TimeInterval
    let scope: PlayerScrubScope
    let currentChapter: Chapter?
    let tint: Color
    @Binding var scrubTime: TimeInterval?
    let onCommit: (TimeInterval) -> Void

    @Environment(\.hearth) private var hearth
    @State private var lastHapticIndex: Int?

    private let gap: CGFloat = 2
    private let baseHeight: CGFloat = 5
    private let currentHeight: CGFloat = 8
    private let hitHeight: CGFloat = 30
    private let bubbleWidth: CGFloat = 76

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let time = scrubTime ?? currentTime
            HStack(spacing: gap) {
                if scope == .chapter, let currentChapter {
                    segment(width: width, height: currentHeight, fill: fraction(of: time, in: currentChapter))
                } else if !hasUsableBookTimeline {
                    segment(width: width, height: currentHeight, fill: bookFraction(of: time))
                } else {
                    let available = max(1, width - gap * CGFloat(chapters.count - 1))
                    let current = currentIndex(at: time)
                    ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                        let segWidth = available * CGFloat(chapter.duration / max(duration, 1))
                        segment(
                            width: max(segWidth, 2),
                            height: index == current ? currentHeight : baseHeight,
                            fill: segmentFill(chapter: chapter, time: time)
                        )
                    }
                }
            }
            .frame(width: width, height: hitHeight)
            .contentShape(Rectangle())
            .gesture(drag(width: width))
            .overlay(alignment: .topLeading) {
                if let scrubTime {
                    bubble(time: scrubTime, width: width)
                }
            }
            .animation(.snappy(duration: 0.18), value: currentIndex(at: time))
        }
        .frame(height: hitHeight)
    }

    private func segment(width: CGFloat, height: CGFloat, fill: Double) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(trackColor)
            Rectangle()
                .fill(tint)
                .frame(width: width * CGFloat(min(max(fill, 0), 1)))
        }
        .clipShape(Capsule())
        .frame(width: width, height: height)
    }

    private func bubble(time: TimeInterval, width: CGFloat) -> some View {
        let x = CGFloat(scrubFraction(of: time)) * width
        return Text(HearthFormat.clock(time))
            .font(.hearthUI(13, weight: .semibold).monospacedDigit())
            .foregroundStyle(hearth.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                HearthChromeBackground(
                    shape: .capsule,
                    fill: hearth.bgElevated,
                    stroke: hearth.hairline,
                    tint: tint,
                    shadow: true
                )
            }
            .frame(width: bubbleWidth)
            .offset(x: min(max(x - bubbleWidth / 2, 0), width - bubbleWidth), y: -44)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let time = time(at: value.location.x, width: width) else { return }
                if scrubTime == nil {
                    PlatformHaptics.impact(.light)
                    lastHapticIndex = currentIndex(at: time)
                } else if let index = currentIndex(at: time), index != lastHapticIndex {
                    PlatformHaptics.selection()
                    lastHapticIndex = index
                }
                scrubTime = time
            }
            .onEnded { value in
                defer { scrubTime = nil }
                guard let time = time(at: value.location.x, width: width) else { return }
                PlatformHaptics.impact(.medium)
                onCommit(time)
            }
    }

    private func time(at x: CGFloat, width: CGFloat) -> TimeInterval? {
        guard width > 0, duration > 0 else { return nil }
        let fraction = Double(min(max(x / width, 0), 1))
        if scope == .chapter, let currentChapter {
            return currentChapter.start + fraction * currentChapter.duration
        }
        return fraction * duration
    }

    private func scrubFraction(of time: TimeInterval) -> Double {
        if scope == .chapter, let currentChapter {
            return fraction(of: time, in: currentChapter)
        }
        return bookFraction(of: time)
    }

    private func bookFraction(of time: TimeInterval) -> Double {
        duration > 0 ? min(max(time / duration, 0), 1) : 0
    }

    private func fraction(of time: TimeInterval, in chapter: Chapter) -> Double {
        chapter.duration > 0 ? min(max((time - chapter.start) / chapter.duration, 0), 1) : 0
    }

    private func segmentFill(chapter: Chapter, time: TimeInterval) -> Double {
        guard chapter.duration > 0 else { return time >= chapter.end ? 1 : 0 }
        return (time - chapter.start) / chapter.duration
    }

    private func currentIndex(at time: TimeInterval) -> Int? {
        guard !chapters.isEmpty else { return nil }
        return chapters.lastIndex { $0.start <= time } ?? 0
    }

    private var hasUsableBookTimeline: Bool {
        guard duration > 0, !chapters.isEmpty else { return false }
        guard chapters.allSatisfy({ $0.duration > 0 }) else { return false }
        guard chapters.first?.start ?? duration <= max(1, duration * 0.01) else { return false }
        guard chapters.last?.end ?? 0 >= duration * 0.9 else { return false }
        return zip(chapters, chapters.dropFirst()).allSatisfy { previous, next in
            next.start >= previous.start && next.end > previous.end
        }
    }

    private var trackColor: Color {
        hearth.isInk ? .white.opacity(0.14) : .black.opacity(0.10)
    }
}
