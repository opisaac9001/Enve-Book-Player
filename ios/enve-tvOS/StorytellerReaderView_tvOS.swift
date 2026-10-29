import SwiftUI
import UIKit

struct StorytellerReaderView_tvOS: View {
    let book: Book

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.hearth) private var hearth
    @AppStorage("storyteller.tv.readAlongFontSize") private var fontSize: Double = 40

    @StateObject private var player = TVStorytellerAudioPlayer()
    @State private var loadState: LoadState = .loading
    @State private var loadAttempt = 0
    @State private var chapters: [TVStorytellerChapter] = []
    @State private var alignment = Alignment()
    @State private var browsingClip: Int?
    @State private var controlsLocked = true
    @State private var controlsHidden = false
    @State private var hideTask: Task<Void, Never>?
    @State private var showsChapterPicker = false
    @State private var showsTextOnly = false
    @State private var artwork: UIImage?
    @FocusState private var focus: Focus?

    private static let rates: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    private static let fontSizeRange: ClosedRange<Double> = 28...64

    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private enum Focus: String, Hashable {
        case reading, previous, back15, playPause, forward15, next, speed, chapters, smaller, larger, follow
    }

    var body: some View {
        ZStack {
            background
            switch loadState {
            case .loading:
                loadingState
            case .failed(let message):
                failedState(message: message)
            case .ready:
                readerBody
            }
        }
        .onPlayPauseCommand {
            if loadState == .ready { player.togglePlayPause() }
        }
        .onExitCommand(perform: handleExit)
        .task(id: loadAttempt) { await load() }
        .onChange(of: player.isPlaying) { scheduleAutoHide() }
        .onChange(of: showsChapterPicker) { scheduleAutoHide() }
        .onChange(of: focus) { _, newFocus in
            if newFocus == .reading { controlsLocked = true }
            scheduleAutoHide()
        }
        .onChange(of: controlsLocked) { _, locked in
            if !locked { DispatchQueue.main.async { focus = .playPause } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { player.pause() }
        }
        .onDisappear {
            hideTask?.cancel()
            player.cleanup()
        }
        .sheet(isPresented: $showsChapterPicker, onDismiss: {
            controlsLocked = true
            DispatchQueue.main.async { focus = .reading }
        }) {
            ChapterPicker(options: chapterOptions, currentID: narratedChapterIndex.map { chapters[$0].id }) { option in
                browsingClip = nil
                player.seek(toClipAt: option.firstClip)
                showsChapterPicker = false
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: controlsHidden)
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showsTextOnly) {
            EbookReaderView_tvOS(book: book)
        }
    }

    private var background: some View {
        ZStack {
            hearth.bgSunken
            if contrast != .increased {
                if let artwork {
                    GeometryReader { geometry in
                        Image(uiImage: artwork)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                            .blur(radius: 100)
                            .opacity(0.18)
                    }
                } else {
                    RadialGradient(
                        colors: [hearth.ember.opacity(0.2), .clear],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 1400
                    )
                }
            }
        }
        .ignoresSafeArea()
    }

    private var loadingState: some View {
        VStack(spacing: 32) {
            ProgressView()
            Text("Preparing read-along…")
                .font(.title3)
                .foregroundStyle(hearth.textSecondary)
            Button("Done") { dismiss() }
                .accessibilityIdentifier("readAlong.done")
        }
    }

    private func failedState(message: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 80))
                .foregroundStyle(hearth.ember)
                .accessibilityHidden(true)
            Text("Can't start read-along")
                .font(.title.weight(.bold))
                .foregroundStyle(hearth.text)
            Text(message)
                .font(.title3)
                .foregroundStyle(hearth.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 800)
            HStack(spacing: 24) {
                Button("Retry") { loadAttempt += 1 }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("readAlong.retry")
                Button("Read Text Only") {
                    player.cleanup()
                    showsTextOnly = true
                }
                .accessibilityIdentifier("readAlong.textOnly")
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("readAlong.done")
            }
            .padding(.top, 24)
        }
    }

    private var readerBody: some View {
        HStack(alignment: .top, spacing: 80) {
            sidebar
                .frame(width: 560)
            readingSurface
        }
        .padding(.vertical, 20)
        .defaultFocus($focus, .reading)
    }

    private var sidebar: some View {
        let chapterIndex = narratedChapterIndex
        return VStack(alignment: .leading, spacing: 28) {
            cover

            VStack(alignment: .leading, spacing: 8) {
                Text(book.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(hearth.text)
                    .lineLimit(3)
                if let author = book.author, !author.isEmpty {
                    Text(author)
                        .font(.headline)
                        .foregroundStyle(hearth.textSecondary)
                        .lineLimit(2)
                }
            }

            if let chapterIndex {
                chapterProgress(chapterIndex)
            }

            if let error = player.playbackError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(hearth.ember)
            }

            Spacer(minLength: 0)

            controls
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var cover: some View {
        CachedAsyncCoverImage(
            url: book.coverURL,
            fallbackColor: "Blue",
            headers: CachedAsyncCoverImage.authHeaders(for: book),
            book: book,
            contentMode: .fit,
            onImageChange: { artwork = $0 }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: 340, maxHeight: 380, alignment: .leading)
        .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
        .accessibilityHidden(true)
    }

    private func chapterProgress(_ index: Int) -> some View {
        let times = alignment.chapterTimes[index] ?? 0...0
        let total = times.upperBound - times.lowerBound
        let elapsed = min(max(player.elapsedTime - times.lowerBound, 0), total)
        let bookFraction = player.duration > 0 ? min(player.elapsedTime / player.duration, 1) : 0

        return VStack(alignment: .leading, spacing: 12) {
            Text(chapters[index].title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(hearth.text)
                .lineLimit(3)
            ProgressView(value: elapsed, total: max(total, 1))
                .tint(hearth.ember)
            HStack {
                Text(clock(elapsed))
                Spacer()
                Text("-\(clock(total - elapsed))")
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(hearth.textSecondary)
            Text("\(bookFraction.formatted(.percent.precision(.fractionLength(0)))) of book")
                .font(.caption)
                .foregroundStyle(hearth.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chapters[index].title)
        .accessibilityValue("\(clock(elapsed)) elapsed, \(clock(total - elapsed)) remaining in chapter")
        .accessibilityIdentifier("readAlong.chapterProgress")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                controlButton("Previous passage", "backward.end.fill", .previous) {
                    browsingClip = nil
                    player.previous()
                }
                controlButton("Skip back 15 seconds", "gobackward.15", .back15) { skip(by: -15) }
                controlButton(player.isPlaying ? "Pause" : "Play", player.isPlaying ? "pause.fill" : "play.fill", .playPause) {
                    player.togglePlayPause()
                }
                controlButton("Skip forward 15 seconds", "goforward.15", .forward15) { skip(by: 15) }
                controlButton("Next passage", "forward.end.fill", .next) {
                    browsingClip = nil
                    player.next()
                }
            }
            HStack(spacing: 14) {
                speedMenu
                controlButton("Chapters", "list.bullet", .chapters) { showsChapterPicker = true }
                controlButton("Smaller text", "textformat.size.smaller", .smaller) { adjustFontSize(by: -4) }
                controlButton("Larger text", "textformat.size.larger", .larger) { adjustFontSize(by: 4) }
            }
            if controlsLocked && !voiceOverEnabled {
                Text("Select for controls  ·  ↑↓ Browse  ·  ←→ Skip 15s")
                    .font(.caption)
                    .foregroundStyle(hearth.textSecondary)
            } else {
                Button {
                    browsingClip = nil
                    controlsLocked = true
                    focus = .reading
                } label: {
                    Label("Follow narration", systemImage: "text.viewfinder")
                        .font(.callout)
                }
                .buttonBorderShape(.capsule)
                .focused($focus, equals: .follow)
                .accessibilityIdentifier("readAlong.follow")
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .focusSection()
        // Locked while the reading surface owns focus so its left/right skips never hand focus to these buttons.
        .disabled(controlsLocked && !voiceOverEnabled)
        .opacity(controlsHidden ? 0 : 1)
        .accessibilityHidden(controlsHidden)
        .onExitCommand(perform: handleExit)
    }

    private func controlButton(
        _ title: String,
        _ systemImage: String,
        _ target: Focus,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.title3)
        }
        .focused($focus, equals: target)
        .accessibilityIdentifier("readAlong.\(target.rawValue)")
    }

    private var speedMenu: some View {
        Menu {
            Picker("Playback Speed", selection: Binding(get: { player.playbackRate }, set: { player.setRate($0) })) {
                ForEach(Self.rates, id: \.self) { rate in
                    Text(rateText(rate)).tag(rate)
                }
            }
        } label: {
            Text(rateText(player.playbackRate))
                .font(.headline.monospacedDigit())
        }
        .buttonBorderShape(.capsule)
        .focused($focus, equals: .speed)
        .accessibilityLabel("Playback speed")
        .accessibilityValue(rateText(player.playbackRate))
        .accessibilityIdentifier("readAlong.speed")
    }

    private var readingSurface: some View {
        let narratedSegment = alignment.segment(forClip: player.currentClipIndex)
        let browsedSegment = browsingClip.flatMap(alignment.segment(forClip:))
        let chapter = displayedChapterIndex.map { chapters[$0] }

        return Button(action: activateReadingSurface) {
            if let chapter {
                PassageList(
                    chapter: chapter,
                    narratedSegment: narratedSegment,
                    browsedSegment: browsedSegment,
                    fontSize: fontSize,
                    accent: hearth.ember,
                    text: hearth.text,
                    textSecondary: hearth.textSecondary,
                    contextOpacity: contrast == .increased ? 0.65 : 0.32,
                    animates: !reduceMotion
                )
                .equatable()
            }
        }
        .buttonStyle(ReadingSurfaceStyle())
        .focused($focus, equals: .reading)
        .onAppear { focus = .reading }
        .onMoveCommand(perform: handleMove)
        .onExitCommand(perform: handleExit)
        .overlay(alignment: .top) {
            if browsingClip != nil {
                Label("Browsing  ·  Select to listen from here", systemImage: "text.viewfinder")
                    .font(.callout)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(hearth.bgElevated, in: Capsule())
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("Read-along text")
        .accessibilityValue(passageText(browsedSegment ?? narratedSegment, in: chapter) ?? "")
        .accessibilityHint(
            browsingClip == nil
                ? "Select to open playback controls. Swipe up or down to browse passages."
                : "Select to play from this passage."
        )
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: browse(by: 1)
            case .decrement: browse(by: -1)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("readAlong.reading")
    }

    private func passageText(_ segmentID: Int?, in chapter: TVStorytellerChapter?) -> String? {
        guard let segmentID else { return nil }
        return chapter?.segments.first { $0.id == segmentID }?.text
    }

    private var narratedChapterIndex: Int? {
        alignment.chapter(forClip: player.currentClipIndex) ?? alignment.chapterClips.keys.min()
    }

    private var displayedChapterIndex: Int? {
        browsingClip.flatMap(alignment.chapter(forClip:)) ?? narratedChapterIndex
    }

    private var chapterOptions: [ChapterOption] {
        chapters.indices.compactMap { index in
            guard let clips = alignment.chapterClips[index], let times = alignment.chapterTimes[index] else { return nil }
            return ChapterOption(
                id: chapters[index].id,
                title: chapters[index].title,
                duration: times.upperBound - times.lowerBound,
                firstClip: clips.lowerBound
            )
        }
    }

    private var canAutoHide: Bool {
        player.isPlaying && controlsLocked && browsingClip == nil && !showsChapterPicker && !voiceOverEnabled
    }

    private func handleMove(_ direction: MoveCommandDirection) {
        switch direction {
        case .up: browse(by: -1)
        case .down: browse(by: 1)
        case .left: skip(by: -15)
        case .right: skip(by: 15)
        @unknown default: break
        }
    }

    private func handleExit() {
        if showsChapterPicker {
            showsChapterPicker = false
        } else if browsingClip != nil {
            browsingClip = nil
        } else if loadState == .ready, controlsLocked {
            controlsHidden = false
            controlsLocked = false
        } else {
            dismiss()
        }
    }

    private func activateReadingSurface() {
        if let browsingClip {
            player.seek(toClipAt: browsingClip)
            self.browsingClip = nil
        } else {
            controlsHidden = false
            controlsLocked = false
        }
    }

    private func browse(by step: Int) {
        let segments = alignment.segmentForClip
        var index = browsingClip ?? player.currentClipIndex
        repeat { index += step } while segments.indices.contains(index) && segments[index] == nil
        guard segments.indices.contains(index) else { return }
        browsingClip = index == player.currentClipIndex ? nil : index
    }

    private func skip(by seconds: TimeInterval) {
        browsingClip = nil
        player.skip(by: seconds)
    }

    private func adjustFontSize(by delta: Double) {
        fontSize = min(max(fontSize + delta, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        controlsHidden = false
        guard canAutoHide else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, canAutoHide else { return }
            controlsHidden = true
        }
    }

    private func load() async {
        loadState = .loading
        do {
            let loaded = try await TVStorytellerLoader.load(book: book)
            guard !Task.isCancelled else { return }
            let alignment = Alignment(chapters: loaded.chapters, clips: loaded.clips)
            guard !alignment.chapterClips.isEmpty else {
                loadState = .failed("This book's narration doesn't match any of its chapter text.")
                return
            }
            chapters = loaded.chapters
            self.alignment = alignment
            browsingClip = nil
            PlayerViewModel.shared.pause()
            player.load(clips: loaded.clips, audioDir: loaded.audioDir)
            player.restorePosition(for: book)
            loadState = .ready
            player.play()
        } catch let error as TVStorytellerLoader.LoadError {
            guard !Task.isCancelled else { return }
            loadState = .failed(error.message)
        } catch {
            guard !Task.isCancelled else { return }
            loadState = .failed(error.localizedDescription)
        }
    }

    private func rateText(_ rate: Double) -> String {
        "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}

private func clock(_ seconds: TimeInterval) -> String {
    let whole = max(0, seconds.rounded(.down))
    return Duration.seconds(whole).formatted(.time(pattern: whole >= 3600 ? .hourMinuteSecond : .minuteSecond))
}

private struct Alignment {
    private(set) var chapterForClip: [Int?] = []
    private(set) var segmentForClip: [Int?] = []
    private(set) var chapterClips: [Int: ClosedRange<Int>] = [:]
    private(set) var chapterTimes: [Int: ClosedRange<TimeInterval>] = [:]

    init() {}

    init(chapters: [TVStorytellerChapter], clips: [TVAudioOverlayClip]) {
        var chapterByHref: [String: Int] = [:]
        var segmentByFragment: [[String: Int]] = []
        for (index, chapter) in chapters.enumerated() {
            let href = TVStorytellerPaths.normalizeHref(chapter.href)
            if chapterByHref[href] == nil { chapterByHref[href] = index }
            var fragments: [String: Int] = [:]
            for segment in chapter.segments {
                if let fragmentId = segment.fragmentId, fragments[fragmentId] == nil {
                    fragments[fragmentId] = segment.id
                }
            }
            segmentByFragment.append(fragments)
        }

        var clipStarts: [TimeInterval] = []
        var elapsed: TimeInterval = 0
        for (clipIndex, clip) in clips.enumerated() {
            clipStarts.append(elapsed)
            elapsed += clip.duration
            let chapter = chapterByHref[TVStorytellerPaths.normalizeHref(clip.textHref)]
            chapterForClip.append(chapter)
            segmentForClip.append(chapter.flatMap { segmentByFragment[$0][clip.fragmentId] })
            if let chapter {
                let existing = chapterClips[chapter]
                chapterClips[chapter] = min(existing?.lowerBound ?? clipIndex, clipIndex)...max(existing?.upperBound ?? clipIndex, clipIndex)
            }
        }
        for (chapter, range) in chapterClips {
            chapterTimes[chapter] = clipStarts[range.lowerBound]...(clipStarts[range.upperBound] + clips[range.upperBound].duration)
        }
    }

    func chapter(forClip clip: Int) -> Int? {
        guard chapterForClip.indices.contains(clip) else { return nil }
        return chapterForClip[clip]
    }

    func segment(forClip clip: Int) -> Int? {
        segmentForClip.indices.contains(clip) ? segmentForClip[clip] : nil
    }
}

private struct ReadingSurfaceStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
    }
}

private struct PassageList: View, Equatable {
    let chapter: TVStorytellerChapter
    let narratedSegment: Int?
    let browsedSegment: Int?
    let fontSize: Double
    let accent: Color
    let text: Color
    let textSecondary: Color
    let contextOpacity: Double
    let animates: Bool

    private var target: Int? { browsedSegment ?? narratedSegment }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: fontSize * 0.7) {
                        if chapter.segments.first?.text != chapter.title {
                            Text(chapter.title)
                                .font(.system(size: fontSize * 0.6, weight: .semibold))
                                .foregroundStyle(textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(chapter.segments) { segment in
                            passage(segment)
                                .id(segment.id)
                        }
                    }
                    // Half-viewport padding lets the first and last passages reach the center.
                    .padding(.vertical, geometry.size.height / 2)
                    .padding(.leading, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .scrollDisabled(true)
                .onAppear { scroll(proxy, animated: false) }
                .onChange(of: target) { scroll(proxy, animated: animates) }
                .onChange(of: fontSize) { scroll(proxy, animated: false) }
                .onChange(of: geometry.size) { scroll(proxy, animated: false) }
            }
            .id(chapter.id)
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.14),
                    .init(color: .black, location: 0.86),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let target else { return }
        withAnimation(animated ? .easeInOut(duration: 0.45) : nil) {
            proxy.scrollTo(target, anchor: .center)
        }
    }

    private func passage(_ segment: TVStorytellerTextSegment) -> some View {
        let isNarrated = segment.id == narratedSegment
        let isBrowsed = segment.id == browsedSegment
        let color: Color =
            if isBrowsed { text } else if isNarrated { browsedSegment == nil ? text : accent } else { text.opacity(contextOpacity) }

        return Text(segment.text)
            .font(.system(size: fontSize, design: .serif))
            .lineSpacing(fontSize * 0.3)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if isBrowsed {
                    Capsule()
                        .fill(accent)
                        .frame(width: 6)
                        .offset(x: -24)
                }
            }
            .animation(animates ? .easeInOut(duration: 0.3) : nil, value: color)
    }
}

private struct ChapterOption: Identifiable {
    let id: Int
    let title: String
    let duration: TimeInterval
    let firstClip: Int
}

private struct ChapterPicker: View {
    @Environment(\.hearth) private var hearth
    let options: [ChapterOption]
    let currentID: Int?
    let select: (ChapterOption) -> Void

    @FocusState private var focused: Int?

    var body: some View {
        NavigationStack {
            List(options) { option in
                Button {
                    select(option)
                } label: {
                    HStack(spacing: 24) {
                        Image(systemName: "checkmark")
                            .opacity(option.id == currentID ? 1 : 0)
                            .accessibilityHidden(true)
                        Text(option.title)
                            .lineLimit(2)
                        Spacer()
                        Text(clock(option.duration))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .focused($focused, equals: option.id)
                .accessibilityAddTraits(option.id == currentID ? .isSelected : [])
                .accessibilityIdentifier("readAlong.chapter.\(option.id)")
            }
            .hearthCanvas()
            .navigationTitle("Chapters")
        }
        .defaultFocus($focused, currentID)
    }
}
