import SwiftUI

struct PlayerView_tvOS: View {
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(\.dismiss) private var dismiss

    @State private var showingChapters = false
    @State private var showingSleepTimer = false
    @State private var showingSpeed = false

    var body: some View {
        ZStack {

            BlurredCoverBackground_tvOS(book: playerVM.currentBook)
                .ignoresSafeArea()

            HStack(spacing: 80) {
                coverSection
                    .frame(maxWidth: .infinity)
                metadataAndTransportSection
                    .frame(maxWidth: .infinity)
            }
            .padding(80)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $showingChapters) {
            ChapterListSheet_tvOS()
        }
        .sheet(isPresented: $showingSleepTimer) {
            SleepTimerSheet_tvOS()
        }
        .sheet(isPresented: $showingSpeed) {
            PlaybackSpeedSheet_tvOS()
        }
    }

    private var coverSection: some View {
        VStack {
            if let url = playerVM.currentBook?.coverURL {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    coverPlaceholder
                }
                .frame(maxWidth: 600, maxHeight: 600)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 30, y: 20)
            } else {
                coverPlaceholder
                    .frame(width: 600, height: 600)
            }
        }
    }

    private var coverPlaceholder: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.secondary.opacity(0.3))
            .overlay(
                Image(systemName: "headphones")
                    .font(.system(size: 96))
                    .foregroundStyle(.secondary)
            )
    }

    private var metadataAndTransportSection: some View {
        VStack(alignment: .leading, spacing: 32) {
            metadataBlock
            chapterBlock
            progressBlock
            transportButtons
            secondaryButtons
        }
    }

    private var metadataBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(playerVM.currentBook?.title ?? "-")
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            if let author = playerVM.currentBook?.author, !author.isEmpty {
                Text(author)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var chapterBlock: some View {
        if let chapter = playerVM.currentChapter {
            VStack(alignment: .leading, spacing: 4) {
                Text("Chapter")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(chapter.title)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)
                .tint(.white)

            HStack {
                Text(formatTime(playerVM.progress))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Text("-\(formatTime(max(0, playerVM.duration - playerVM.progress)))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var progressFraction: Double {
        guard playerVM.duration > 0 else { return 0 }
        return max(0, min(1, playerVM.progress / playerVM.duration))
    }

    private var transportButtons: some View {
        HStack(spacing: 40) {
            transportButton(systemName: "gobackward.30", label: "Back 30s") {
                playerVM.skipBackward()
            }

            Button {
                if playerVM.isPlaying {
                    playerVM.pause()
                } else if let book = playerVM.currentBook {
                    playerVM.play(book: book)
                }
            } label: {
                Image(systemName: playerVM.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

            transportButton(systemName: "goforward.30", label: "Forward 30s") {
                playerVM.skipForward()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func transportButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 40, weight: .medium))
                Text(label)
                    .font(.caption2)
            }
            .foregroundStyle(.primary)
            .frame(width: 140, height: 100)
        }
        .buttonStyle(.plain)
    }

    private var secondaryButtons: some View {
        HStack(spacing: 24) {
            secondaryButton(systemName: "list.bullet", label: chapterButtonLabel) {
                showingChapters = true
            }
            secondaryButton(systemName: "speedometer", label: speedButtonLabel) {
                showingSpeed = true
            }
            secondaryButton(systemName: sleepTimerSymbol, label: sleepTimerLabel) {
                showingSleepTimer = true
            }
        }
    }

    private func secondaryButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemName)
                Text(label)
            }
            .font(.body.weight(.medium))
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .buttonStyle(.bordered)
    }

    private var chapterButtonLabel: String {
        if playerVM.chapters.isEmpty { return "Chapters" }
        return "Chapters (\(playerVM.chapters.count))"
    }

    private var speedButtonLabel: String {
        String(format: "%.1fx", playerVM.playbackSpeed)
    }

    private var sleepTimerSymbol: String {
        playerVM.sleepTimer != nil ? "moon.fill" : "moon"
    }

    private var sleepTimerLabel: String {
        guard playerVM.sleepTimer != nil else { return "Sleep timer" }
        let remaining = max(0, playerVM.sleepTimerRemainingSeconds)
        return formatTime(remaining)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

struct BlurredCoverBackground_tvOS: View {
    let book: Book?

    var body: some View {
        ZStack {
            Color.black
            if let url = book?.coverURL {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 60)
                        .opacity(0.4)
                } placeholder: {
                    Color.clear
                }
            }
            Color.black.opacity(0.5)
        }
    }
}

struct ChapterListSheet_tvOS: View {
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(playerVM.chapters, id: \.id) { chapter in
                    Button {
                        playerVM.seekToChapter(chapter)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(chapter.title)
                                    .font(.body.weight(playerVM.currentChapter?.id == chapter.id ? .bold : .regular))
                                Text(formatChapterRange(chapter))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if playerVM.currentChapter?.id == chapter.id {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Chapters")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func formatChapterRange(_ chapter: Chapter) -> String {
        let start = formatTime(chapter.start)
        let end = formatTime(chapter.end)
        return "\(start) - \(end)"
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

struct SleepTimerSheet_tvOS: View {
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(\.dismiss) private var dismiss

    private let durations = [5, 10, 15, 30, 45, 60, 90]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if playerVM.sleepTimer != nil {
                        Button(role: .destructive) {
                            playerVM.stopSleepTimer()
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "moon.zzz")
                                Text("Cancel sleep timer")
                                Spacer()
                                Text(formatTime(playerVM.sleepTimerRemainingSeconds))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                Section("Duration") {
                    ForEach(durations, id: \.self) { minutes in
                        Button {
                            playerVM.startSleepTimer(minutes: minutes, fadeOut: true)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "clock")
                                Text(durationLabel(minutes))
                                Spacer()
                            }
                        }
                    }
                }

                Section("Chapter-anchored") {
                    if playerVM.currentChapter != nil {
                        Button {
                            playerVM.setSleepTimerToEndOfChapter(fadeOut: true)
                            dismiss()
                        } label: {
                            Label("End of current chapter", systemImage: "stop.circle")
                        }
                    }
                    if nextChapterAvailable {
                        Button {
                            playerVM.setSleepTimerToEndOfNextChapter(fadeOut: true)
                            dismiss()
                        } label: {
                            Label("End of next chapter", systemImage: "forward.end.circle")
                        }
                    }
                }
            }
            .navigationTitle("Sleep timer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var nextChapterAvailable: Bool {
        guard let current = playerVM.currentChapter,
            let idx = playerVM.chapters.firstIndex(where: { $0.id == current.id })
        else {
            return false
        }
        return idx + 1 < playerVM.chapters.count
    }

    private func durationLabel(_ minutes: Int) -> String {
        if minutes >= 60 {
            let hours = minutes / 60
            let remaining = minutes % 60
            return remaining == 0 ? "\(hours)h" : "\(hours)h \(remaining)m"
        }
        return "\(minutes) min"
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

struct PlaybackSpeedSheet_tvOS: View {
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(\.dismiss) private var dismiss

    private let speeds: [Double] = [0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    var body: some View {
        NavigationStack {
            List {
                ForEach(speeds, id: \.self) { speed in
                    Button {
                        playerVM.setPlaybackSpeed(speed)
                        dismiss()
                    } label: {
                        HStack {
                            Text(String(format: "%.2fx", speed))
                                .font(.body.weight(speedMatchesCurrent(speed) ? .bold : .regular))
                            Spacer()
                            if speedMatchesCurrent(speed) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Playback speed")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func speedMatchesCurrent(_ speed: Double) -> Bool {
        abs(playerVM.playbackSpeed - speed) < 0.01
    }
}
