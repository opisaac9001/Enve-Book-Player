import SwiftUI

struct StorytellerReaderView_tvOS: View {
    let book: Book

    @Environment(\.dismiss) private var dismiss

    @StateObject private var player = TVStorytellerAudioPlayer()
    @State private var chapters: [TVStorytellerChapter] = []
    @State private var clipsByFragment: [String: TVAudioOverlayClip] = [:]
    @State private var loadState: LoadState = .loading
    @State private var fontSize: CGFloat = 36
    @State private var showsControls: Bool = true
    @State private var controlsHideTask: Task<Void, Never>?

    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    var body: some View {
        ZStack {
            Color(white: 0.04).ignoresSafeArea()
            content
        }
        .focusable()
        .onPlayPauseCommand {
            player.togglePlayPause(); bumpControls()
        }
        .onMoveCommand { dir in
            guard loadState == .ready else { return }
            bumpControls()
            switch dir {
            case .left: player.previous()
            case .right: player.next()
            default: break
            }
        }
        .task { await load() }
        .onDisappear {
            controlsHideTask?.cancel()
            player.cleanup()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            VStack(spacing: 24) {
                ProgressView().progressViewStyle(.circular).scaleEffect(2)
                Text("Preparing read-along…").font(.title3).foregroundStyle(.secondary)
            }
        case .failed(let message):
            failedState(message: message)
        case .ready:
            readerBody
        }
    }

    private func failedState(message: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 80))
                .foregroundStyle(.orange)
            Text("Can't start read-along").font(.title.weight(.bold))
            Text(message).font(.title3).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 800)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent).padding(.top, 24)
        }
    }

    private var readerBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            chapterHeader
                .padding(.horizontal, 80)
                .padding(.top, 60)
                .padding(.bottom, 24)

            textScroll

            if showsControls {
                transportBar
                    .padding(.horizontal, 80)
                    .padding(.vertical, 28)
                    .background(Material.ultraThin)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showsControls)
    }

    private var chapterHeader: some View {
        Text(currentChapter?.title ?? "")
            .font(.title2.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var textScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let chapter = currentChapter {
                        ForEach(chapter.segments) { segment in
                            segmentView(segment)
                                .id(segment.id)
                        }
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 80)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: player.currentFragmentId) { _, _ in
                if let activeId = activeSegmentId {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        proxy.scrollTo(activeId, anchor: .center)
                    }
                }
            }
        }
    }

    private func segmentView(_ segment: TVStorytellerTextSegment) -> some View {
        let active = (segment.fragmentId == player.currentFragmentId) && segment.fragmentId != nil
        return Text(segment.text)
            .font(.system(size: fontSize, design: .serif))
            .lineSpacing(14)
            .foregroundStyle(active ? Color.white : Color.white.opacity(0.4))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transportBar: some View {
        HStack(spacing: 32) {
            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            .buttonStyle(.plain)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 68))
            }
            .buttonStyle(.plain)

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill").font(.title)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                cycleRate()
            } label: {
                Label(rateLabel, systemImage: "speedometer")
                    .font(.headline)
            }
            .buttonStyle(.bordered)
        }
    }

    private var currentChapter: TVStorytellerChapter? {
        guard let fragId = player.currentFragmentId,
            let clip = clipsByFragment[fragId]
        else {
            return chapters.first
        }
        return chapters.first(where: { matches(chapterHref: $0.href, clipHref: clip.textHref) })
            ?? chapters.first
    }

    private var activeSegmentId: Int? {
        guard let chapter = currentChapter,
            let fragId = player.currentFragmentId
        else { return nil }
        return chapter.segments.first(where: { $0.fragmentId == fragId })?.id
    }

    private func matches(chapterHref: String, clipHref: String) -> Bool {
        let c = TVStorytellerPaths.normalizeHref(chapterHref)
        let h = TVStorytellerPaths.normalizeHref(clipHref)
        return c == h || c.hasSuffix(h) || h.hasSuffix(c)
    }

    private var rateLabel: String {
        String(format: "%.2g×", player.playbackRate)
    }

    private func cycleRate() {
        let presets: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
        let current = player.playbackRate
        let next = presets.first(where: { $0 > current + 0.01 }) ?? presets[0]
        player.setRate(next)
        bumpControls()
    }

    private func bumpControls() {
        showsControls = true
        controlsHideTask?.cancel()
        controlsHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { showsControls = false }
        }
    }

    private func load() async {
        do {
            let loaded = try await TVStorytellerLoader.load(book: book)
            await MainActor.run {
                self.chapters = loaded.chapters
                self.clipsByFragment = Dictionary(
                    loaded.clips.map { ($0.fragmentId, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                self.player.load(clips: loaded.clips, audioDir: loaded.audioDir)
                self.loadState = .ready
                self.player.play()
                self.bumpControls()
            }
        } catch let error as TVStorytellerLoader.LoadError {
            await MainActor.run { self.loadState = .failed(error.message) }
        } catch {
            await MainActor.run { self.loadState = .failed(error.localizedDescription) }
        }
    }
}
