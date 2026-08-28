import SwiftUI

struct PlayerScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var ambient: Color = Hearth.accent
    @State private var sortedChapters: [Chapter] = []
    @State private var scrubTime: TimeInterval?
    @State private var activeSheet: PlayerSheet?
    @State private var sleepChapterLabel: String?
    @State private var linkedEbook: Book?
    @AppStorage("player.showPercentRemaining") private var showPercentRemaining = false
    @AppStorage("player.scrubScope") private var scrubScopeRaw = PlayerScrubScope.book.rawValue

    var body: some View {
        ZStack {
            background
            if let book = engine.playback.currentBook {
                content(book: book)
            } else {
                topRow
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
        }
        .task(id: engine.playback.currentBook?.stableId) {
            guard let book = engine.playback.currentBook else { return }
            ambient = await AmbientColorStore.shared.resolve(for: book)
            linkedEbook = book.mediaType == .audiobook ? await EbookAudiobookLinker.shared.linkedEbookAsync(for: book) : nil
        }
        .onAppear {
            playerVM.refreshFromCurrentPlayback()
            rebuildChapters()
        }
        .task {
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-sleepInsightsFixture") {
                try? await Task.sleep(for: .milliseconds(700))
                activeSheet = .sleep
                return
            }
            if let routeIndex = arguments.firstIndex(of: "-imagineScreen"),
                arguments.indices.contains(routeIndex + 1)
            {
                try? await Task.sleep(for: .milliseconds(700))
                switch arguments[routeIndex + 1] {
                case "queue": activeSheet = .queue
                case "leveling": activeSheet = .audio
                default: break
                }
            }
            #endif
        }
        .onChange(of: engine.playback.currentBook?.stableId) {
            playerVM.refreshFromCurrentPlayback()
            rebuildChapters()
        }
        .onChange(of: playerVM.chapters) { rebuildChapters() }
        .onChange(of: playerVM.currentBook?.chapters) { rebuildChapters() }
        .onChange(of: playerVM.duration) { rebuildChapters() }
        .onChange(of: playerVM.sleepTimer) { _, timer in
            if timer == nil { sleepChapterLabel = nil }
        }
        .onDisappear {
            engine.playback.dismissPlayer()
        }
        .sheet(item: $activeSheet) { sheet in
            Group {
                switch sheet {
                case .speed:
                    PlayerSpeedSheet(tint: ambient)
                        .presentationDetents([.height(380)])
                case .sleep:
                    PlayerSleepSheet(tint: ambient, chapters: sortedChapters, chapterLabel: $sleepChapterLabel)
                        .presentationDetents([.medium, .large])
                case .chapters:
                    PlayerChaptersSheet(chapters: sortedChapters, currentIndex: currentChapterIndex, tint: ambient)
                        .presentationDetents([.medium, .large])
                case .bookmarks:
                    PlayerBookmarksSheet(tint: ambient)
                        .presentationDetents([.medium, .large])
                case .audio:
                    PlayerAudioSheet(tint: ambient)
                        .presentationDetents([.medium, .large])
                case .queue:
                    PlayerQueueSheet(tint: ambient)
                        .presentationDetents([.medium, .large])
                case .ambient:
                    PlayerAmbientSheet(tint: ambient)
                        .presentationDetents([.medium, .large])
                case .librarian:
                    if let book = engine.playback.currentBook {
                        LibrarianChatScreen(book: book)
                            .presentationDetents([.large])
                    }
                }
            }
            .hearthPresentationBackground()
            .presentationDragIndicator(.visible)
            .enveEnvironment()
        }
        .alert("Two places in this book", isPresented: syncConflictPresented) {
            if let conflict = playerVM.playbackConflict {
                Button("Stay here (\(HearthFormat.clock(conflict.local)))") {
                    playerVM.resolvePlaybackConflict(useServer: false)
                }
                Button("Go to server (\(HearthFormat.clock(conflict.server)))") {
                    playerVM.resolvePlaybackConflict(useServer: true)
                }
                Button("Not now", role: .cancel) { playerVM.dismissPlaybackConflict() }
            }
        } message: {
            Text("This device and the server remember different positions. Choose where to pick up.")
        }
    }

    private func content(book: Book) -> some View {
        GeometryReader { geo in
            let coverWidth = dynamicTypeSize.isAccessibilitySize
                ? min(geo.size.width * 0.56, 220)
                : min(geo.size.width * 0.78, (geo.size.height * 0.42) / book.hearthCoverRatio)
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView {
                    playerLayout(book: book, coverWidth: coverWidth)
                }
                .scrollIndicators(.hidden)
            } else {
                playerLayout(book: book, coverWidth: coverWidth)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    private func playerLayout(book: Book, coverWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            topRow
                .padding(.horizontal, 20)
            Spacer(minLength: 12)
            CoverTile(book: book, width: coverWidth)
                .shadow(color: ambient.opacity(0.25), radius: 24, y: 8)
                .accessibilityHidden(true)
            Spacer(minLength: 22)
            titleBlock(book: book)
            Spacer(minLength: 22)
            ribbonSection
                .padding(.horizontal, 28)
            Spacer(minLength: 20)
            transportRow(book: book)
            Spacer(minLength: 18)
            utilityRow(book: book)
                .padding(.horizontal, 20)
        }
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private var topRow: some View {
        HStack {
            GlyphButton(systemImage: "chevron.down", label: "Close player") { dismiss() }
            Spacer()
            if linkedEbook != nil {
                GlyphButton(systemImage: "book", label: "Switch to reading", action: switchToReading)
            }
            queueButton
            PlayerAirPlayButton(tint: hearth.text, activeTint: ambient)
                .frame(width: 44, height: 44)
                .background {
                    HearthChromeBackground(
                        shape: .circle,
                        fill: hearth.bgElevated,
                        stroke: hearth.hairline,
                        tint: hearth.bgElevated
                    )
                }
                .accessibilityLabel("AirPlay")
        }
    }

    private var queueButton: some View {
        let count = engine.playback.queue.entries.count
        return ZStack(alignment: .topTrailing) {
            GlyphButton(
                systemImage: "text.line.first.and.arrowtriangle.forward",
                label: count == 0 ? "Up Next" : "Up Next, \(count) items"
            ) {
                activeSheet = .queue
            }
            if count > 0 {
                Text(count > 99 ? "99+" : "\(count)")
                    .font(.hearthUI(9, weight: .bold).monospacedDigit())
                    .foregroundStyle(HearthPalette.readableForeground(on: ambient, dark: hearth.onEmber))
                    .padding(.horizontal, 5)
                    .frame(minWidth: 17, minHeight: 17)
                    .background(Capsule().fill(ambient))
                    .offset(x: 2, y: -1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private func switchToReading() {
        guard let ebook = linkedEbook else { return }
        PlatformHaptics.impact(.light)
        engine.playback.presentReaderAfterDismissingPlayer(for: ebook)
    }

    private func titleBlock(book: Book) -> some View {
        VStack(spacing: 7) {
            if let overline = chapterOverline {
                Overline(overline, color: ambient)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
            Text(book.title)
                .font(.hearthDisplay(24, weight: .semibold))
                .foregroundStyle(hearth.text)
                .multilineTextAlignment(.center)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            if let author = book.author {
                Text(author)
                    .font(.hearthUI(14))
                    .foregroundStyle(hearth.text)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
        }
        .padding(.horizontal, 28)
    }

    private var ribbonSection: some View {
        VStack(spacing: 10) {
            PlayerChapterRibbon(
                chapters: sortedChapters,
                duration: totalDuration,
                currentTime: playerVM.progress,
                scope: activeScrubScope,
                currentChapter: activeChapter,
                tint: ambient,
                scrubTime: $scrubTime
            ) { time in
                guard playerVM.isPlaybackLoaded else { return }
                playerVM.seek(to: playerVM.duration > 0 ? min(time, playerVM.duration) : time)
            }
            PlayerScrubScopeToggle(
                selection: Binding(
                    get: { activeScrubScope },
                    set: { scrubScope = $0 }
                ),
                chapterEnabled: chapterScrubbingAvailable,
                tint: ambient
            )
            HStack(spacing: 8) {
                Text(scrubLeftLabel)
                Spacer()
                if let centerLabel = scrubCenterLabel {
                    Text(centerLabel)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer()
                }
                Text(scrubRightLabel)
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard activeScrubScope == .book else { return }
                        showPercentRemaining.toggle()
                        PlatformHaptics.selection()
                    }
            }
            .font(.hearthUI(13, weight: .semibold).monospacedDigit())
            .foregroundStyle(hearth.text)
            .padding(.horizontal, 12)
            .background {
                HearthChromeBackground(
                    shape: .capsule,
                    fill: hearth.bgElevated.opacity(0.94),
                    stroke: hearth.hairline,
                    tint: hearth.bgElevated
                )
            }
        }
    }

    private func transportRow(book: Book) -> some View {
        HStack(spacing: 38) {
            GlyphButton(
                systemImage: skipBackGlyph,
                size: 56,
                glyphSize: 22,
                label: "Skip back \(Int(playerVM.preferences.skipBackwardAmount)) seconds"
            ) {
                PlatformHaptics.impact(.light)
                playerVM.skipBackward()
            }
            .disabled(!playerVM.isPlaybackLoaded)
            PlayerPlayCircle(isPlaying: playerVM.isPlaying, isLoading: playerVM.isLoading, tint: ambient) {
                PlatformHaptics.impact(.medium)
                if !playerVM.isPlaybackLoaded || playerVM.currentBook?.stableId != book.stableId {
                    engine.playback.play(book)
                } else {
                    playerVM.togglePlay()
                }
            }
            GlyphButton(
                systemImage: skipForwardGlyph,
                size: 56,
                glyphSize: 22,
                label: "Skip forward \(Int(playerVM.preferences.skipForwardAmount)) seconds"
            ) {
                PlatformHaptics.impact(.light)
                playerVM.skipForward()
            }
            .disabled(!playerVM.isPlaybackLoaded)
        }
    }

    private func utilityRow(book: Book) -> some View {
        HStack(spacing: 8) {
            PlayerUtilityPill(glyph: "gauge.with.needle", label: speedLabel) { activeSheet = .speed }
            PlayerUtilityPill(glyph: "moon.zzz", label: sleepLabel, tint: playerVM.sleepTimer != nil ? ambient : nil) {
                activeSheet = .sleep
            }
            PlayerUtilityPill(glyph: "list.bullet", label: "Chapters", disabled: sortedChapters.isEmpty) {
                activeSheet = .chapters
            }
            PlayerUtilityPill(glyph: "waveform", label: "Audio") { activeSheet = .audio }
            Menu {
                Button {
                    activeSheet = .bookmarks
                } label: {
                    Label("Bookmarks", systemImage: "bookmark")
                }
                Button {
                    activeSheet = .ambient
                } label: {
                    Label("Ambient sound", systemImage: "water.waves")
                }
                if BookIntelligenceSettingsStore.shared.showPlayerButton && !book.isPodcastEpisode {
                    Button {
                        activeSheet = .librarian
                    } label: {
                        Label("Ask the Librarian", systemImage: "books.vertical")
                    }
                }
            } label: {
                PlayerUtilityPillLabel(glyph: "ellipsis", label: nil, tint: nil)
                    .frame(width: 52, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More player tools")
        }
    }

    private var background: some View {
        ZStack {
            hearth.bgSunken.ignoresSafeArea()
            EmberGlow(tint: ambient, isBreathing: playerVM.isPlaying)
                .ignoresSafeArea()
            LinearGradient(
                colors: [.clear, .black.opacity(hearth.isInk ? 0.5 : 0.12)],
                startPoint: UnitPoint(x: 0.5, y: 0.45),
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    private var displayTime: TimeInterval { scrubTime ?? playerVM.progress }

    private var scrubScope: PlayerScrubScope {
        get { PlayerScrubScope(rawValue: scrubScopeRaw) ?? .book }
        nonmutating set { scrubScopeRaw = newValue.rawValue }
    }

    private var activeScrubScope: PlayerScrubScope {
        scrubScope == .chapter && chapterScrubbingAvailable ? .chapter : .book
    }

    private var totalDuration: TimeInterval {
        max(playerVM.duration, engine.playback.currentDurationFallback)
    }

    private var currentChapterIndex: Int? {
        guard !sortedChapters.isEmpty else { return nil }
        return sortedChapters.lastIndex { $0.start <= displayTime } ?? 0
    }

    private var activeChapter: Chapter? {
        guard let index = currentChapterIndex else { return nil }
        return sortedChapters[index]
    }

    private var chapterScrubbingAvailable: Bool {
        guard let chapter = activeChapter, chapter.duration > 0 else { return false }
        return displayTime >= chapter.start && displayTime <= chapter.end
    }

    private var chapterOverline: String? {
        guard let index = currentChapterIndex else { return nil }
        let label = "Chapter \(index + 1)"
        let title = sortedChapters[index].title.trimmingCharacters(in: .whitespaces)
        if title.isEmpty || title.lowercased() == label.lowercased() { return label }

        if title.lowercased().hasPrefix("chapter") { return title }
        return "\(label) · \(title)"
    }

    private var scrubLeftLabel: String {
        guard activeScrubScope == .chapter, let chapter = activeChapter else {
            return HearthFormat.clock(displayTime)
        }
        return HearthFormat.duration(max(0, displayTime - chapter.start))
    }

    private var scrubCenterLabel: String? {
        guard let index = currentChapterIndex else { return nil }
        if activeScrubScope == .chapter {
            return chapterLabel(at: index)
        }
        let left = max(0, sortedChapters[index].end - displayTime)
        return HearthFormat.duration(left) + " in chapter"
    }

    private func chapterLabel(at index: Int) -> String {
        let fallback = "Chapter \(index + 1)"
        let title = sortedChapters[index].title.trimmingCharacters(in: .whitespaces)
        return title.lowercased().hasPrefix("chapter") ? title : fallback
    }

    private var scrubRightLabel: String {
        if activeScrubScope == .chapter, let chapter = activeChapter {
            let speed = playerVM.playbackSpeed
            let remaining = max(0, chapter.end - displayTime)
            let atSpeed = speed > 0 ? remaining / speed : remaining
            let base = "-" + HearthFormat.duration(atSpeed)
            return abs(speed - 1.0) < 0.01 ? base : base + " at " + speedLabel
        }
        return remainingLabel
    }

    private var remainingLabel: String {
        if showPercentRemaining {
            let fraction = totalDuration > 0 ? min(max(displayTime / totalDuration, 0), 1) : 0
            return "\(Int((fraction * 100).rounded()))% complete"
        }
        let speed = playerVM.playbackSpeed
        let remaining = max(0, totalDuration - displayTime)
        let atSpeed = speed > 0 ? remaining / speed : remaining
        let base = "-" + HearthFormat.duration(atSpeed)
        return abs(speed - 1.0) < 0.01 ? base : base + " at " + speedLabel
    }

    private var speedLabel: String {
        let rounded = (playerVM.playbackSpeed * 100).rounded() / 100
        return String(format: "%g×", rounded)
    }

    private var sleepLabel: String {
        guard playerVM.sleepTimer != nil else { return "Sleep" }
        if let sleepChapterLabel { return sleepChapterLabel }
        return HearthFormat.clock(playerVM.sleepTimerRemainingSeconds)
    }

    private static let skipGlyphSteps: Set<Int> = [10, 15, 30, 45, 60, 75, 90]

    private var skipBackGlyph: String {
        let n = Int(playerVM.preferences.skipBackwardAmount)
        return Self.skipGlyphSteps.contains(n) ? "gobackward.\(n)" : "gobackward"
    }

    private var skipForwardGlyph: String {
        let n = Int(playerVM.preferences.skipForwardAmount)
        return Self.skipGlyphSteps.contains(n) ? "goforward.\(n)" : "goforward"
    }

    private func rebuildChapters() {
        let playbackChapters = playerVM.currentBook?.chapters ?? []
        let sourceChapters = playbackChapters.isEmpty ? playerVM.chapters : playbackChapters
        let raw = sourceChapters.sorted {
            if $0.start == $1.start { return $0.end < $1.end }
            return $0.start < $1.start
        }

        sortedChapters = raw.enumerated().map { index, chapter in
            let start = max(chapter.start, 0)
            let nextStart = raw.indices.contains(index + 1) ? max(raw[index + 1].start, start) : nil
            let fallbackEnd = nextStart ?? (totalDuration > 0 ? totalDuration : start + 1)
            let repairedEnd = chapter.end > start ? chapter.end : fallbackEnd
            let end = max(min(repairedEnd, fallbackEnd), start + 1)
            return Chapter(id: chapter.id, start: start, end: end, title: chapter.title, index: chapter.index)
        }
    }

    private var syncConflictPresented: Binding<Bool> {
        Binding(
            get: { playerVM.playbackConflict != nil },
            set: { if !$0 { playerVM.dismissPlaybackConflict() } }
        )
    }

}

private enum PlayerSheet: String, Identifiable {
    case speed, sleep, chapters, bookmarks, audio, queue, ambient, librarian
    var id: String { rawValue }
}

private struct PlayerScrubScopeToggle: View {
    @Binding var selection: PlayerScrubScope
    let chapterEnabled: Bool
    let tint: Color

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PlayerScrubScope.allCases) { scope in
                Button {
                    guard scope == .book || chapterEnabled else { return }
                    selection = scope
                    PlatformHaptics.selection()
                } label: {
                    Text(scope.title)
                        .font(.hearthUI(12, weight: selection == scope ? .semibold : .medium))
                        .foregroundStyle(foreground(for: scope))
                        .frame(minWidth: 76)
                        .padding(.vertical, 7)
                        .background {
                            Capsule()
                                .fill(selection == scope ? tint : .clear)
                        }
                }
                .buttonStyle(PressableStyle())
                .disabled(scope == .chapter && !chapterEnabled)
            }
        }
        .padding(3)
        .background {
            HearthChromeBackground(
                shape: .capsule,
                fill: hearth.bgElevated,
                stroke: hearth.hairline,
                tint: hearth.bgElevated
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Scrub range")
    }

    private func foreground(for scope: PlayerScrubScope) -> Color {
        if selection == scope {
            return HearthPalette.readableForeground(on: tint, dark: hearth.onEmber)
        }
        return hearth.text
    }
}

private struct PlayerPlayCircle: View {
    let isPlaying: Bool
    let isLoading: Bool
    let tint: Color
    let action: () -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        Button(action: action) {
            ZStack {
                HearthChromeBackground(
                    shape: .circle,
                    fill: tint,
                    tint: tint
                )
                .shadow(color: tint.opacity(0.35), radius: 18, y: 6)
                if isLoading {
                    ProgressView()
                        .tint(glyphColor)
                } else {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.hearthUI(30, weight: .bold))
                        .foregroundStyle(glyphColor)
                        .offset(x: isPlaying ? 0 : 2)
                }
            }
            .frame(width: 76, height: 76)
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }

    private var glyphColor: Color {
        HearthPalette.readableForeground(on: tint, dark: hearth.onEmber)
    }
}

private struct PlayerUtilityPill: View {
    let glyph: String
    let label: String
    var tint: Color?
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button {
            PlatformHaptics.selection()
            action()
        } label: {
            ViewThatFits(in: .horizontal) {
                PlayerUtilityPillLabel(glyph: glyph, label: label, tint: tint)
                PlayerUtilityPillLabel(glyph: glyph, label: nil, tint: tint)
            }
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressableStyle())
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}

private struct PlayerUtilityPillLabel: View {
    let glyph: String
    let label: String?
    let tint: Color?

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: glyph)
                .font(.hearthUI(13, weight: .medium))
            if let label {
                Text(label)
                    .font(.hearthUI(13, weight: .medium).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .foregroundStyle(tint ?? hearth.text)
        .padding(.vertical, 11)
        .padding(.horizontal, 6)
        .background {
            HearthChromeBackground(
                shape: .capsule,
                fill: hearth.bgElevated,
                stroke: tint?.opacity(0.5) ?? hearth.hairline,
                tint: tint ?? hearth.bgElevated
            )
        }
    }
}
