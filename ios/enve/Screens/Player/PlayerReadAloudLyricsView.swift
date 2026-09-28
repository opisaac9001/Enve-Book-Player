import SwiftUI

struct PlayerReadAloudLyricsView: View {
    let book: Book
    let width: CGFloat
    let currentTime: TimeInterval
    let ambient: Color
    let onSeek: (TimeInterval) -> Void

    @Environment(\.hearth) private var hearth
    @State private var lines: [ReadAloudLyricLine] = []
    @State private var loadedHref: String?

    private var height: CGFloat { width * book.hearthCoverRatio }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                .fill(ambient.opacity(0.12))
            RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                .strokeBorder(hearth.hairline.opacity(0.7), lineWidth: 1)
            content
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous))
        .accessibilityIdentifier("Player.ReadMode")
        .task(id: activeHref) { await loadLines() }
    }

    @ViewBuilder
    private var content: some View {
        if lines.isEmpty {
            VStack(spacing: 8) {
                StorytellerReadAloudMark()
                    .frame(width: 20, height: 23)
                    .foregroundStyle(hearth.textSecondary.opacity(0.5))
                Text(timeline == nil ? "Preparing the narration…" : "No narrated text for this chapter.")
                    .font(.hearthUI(12))
                    .foregroundStyle(hearth.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
        } else {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        Color.clear.frame(height: height * 0.42)
                        ForEach(lines) { line in
                            row(line).id(line.id)
                        }
                        Color.clear.frame(height: height * 0.34)
                    }
                    .padding(.horizontal, 20)
                }
                .onChange(of: activeLineId) { _, active in
                    guard let active else { return }
                    withAnimation(.easeInOut(duration: 0.4)) {
                        proxy.scrollTo(active, anchor: .center)
                    }
                }
                .onAppear {
                    guard let activeLineId else { return }
                    proxy.scrollTo(activeLineId, anchor: .center)
                }
            }
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.35), location: 0.10),
                        .init(color: .black, location: 0.30),
                        .init(color: .black, location: 0.70),
                        .init(color: .black.opacity(0.35), location: 0.90),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    private func row(_ line: ReadAloudLyricLine) -> some View {
        let isActive = line.id == activeLineId
        return Text(line.text)
            .font(.hearthDisplay(isActive ? 19 : 16, weight: isActive ? .semibold : .regular))
            .foregroundStyle(hearth.text.opacity(isActive ? 1 : 0.4))
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture { seek(to: line) }
            .animation(.easeInOut(duration: 0.28), value: isActive)
            .accessibilityLabel(line.text)
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    private var timeline: MediaOverlayTimeline? {
        MediaOverlayPlaybackService.shared.activeResult?.timeline
    }

    private var activeClipIndex: Int? {
        timeline?.clipIndex(atAudioTime: currentTime)
    }

    private var activeHref: String? {
        guard let index = activeClipIndex, let clips = timeline?.clips, clips.indices.contains(index)
        else { return nil }
        return clips[index].textHref
    }

    private var activeLineId: String? {
        guard let index = activeClipIndex, let clips = timeline?.clips, clips.indices.contains(index)
        else { return nil }
        return clips[index].fragmentId
    }

    private func seek(to line: ReadAloudLyricLine) {
        guard let audioTime = timeline?.audioTime(forClipIndex: line.clipIndex) else { return }
        PlatformHaptics.selection()
        onSeek(audioTime)
    }

    private func loadLines() async {
        guard let href = activeHref, href != loadedHref else { return }
        guard let clips = timeline?.clips,
            let epubURL = LocalEbookImporter.shared.resolveEbookForOverlay(book: book),
            let html = await ReadAloudLyricsBuilder.chapterHTML(epubURL: epubURL, href: href)
        else { return }
        lines = ReadAloudLyricsBuilder.lines(for: clips, inHTML: html, matching: href)
        loadedHref = href
    }
}
