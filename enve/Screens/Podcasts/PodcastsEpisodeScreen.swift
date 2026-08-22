import SwiftUI

struct PodcastsEpisodeScreen: View {
    let episode: Book

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var notesExpanded = false
    @State private var tint: Color = Hearth.accent

    private var isDownloaded: Bool {
        engine.downloads.isAudiobookDownloaded(downloadKey: episode.downloadKey)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header

                if episode.isStarted && !episode.isFinished {
                    progressSection
                }

                actions
                metadataChips

                if let notes = episode.description, !notes.isEmpty {
                    notesSection(notes)
                }

                if let showName = episode.podcastName, !showName.isEmpty {
                    showFooter(showName)
                }
            }
            .padding(.top, 8)
            .padding(.horizontal, 24)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .hearthBackBar()
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            tint = await AmbientColorStore.shared.resolve(for: episode)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            PodcastsArt(url: episode.coverURL, size: 118, book: episode)
                .shadow(color: tint.opacity(0.25), radius: 24, y: 8)

            VStack(alignment: .leading, spacing: 5) {
                Overline("The episode")
                Text(episode.title)
                    .font(.hearthDisplay(20, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .lineLimit(4)
                if let show = episode.podcastName {
                    Text(show)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.ember)
                        .lineLimit(2)
                }
                if let date = episode.addedAt {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.hearthUI(12))
                        .foregroundStyle(hearth.textTertiary)
                }
                if episode.isFinished {
                    Label("Played", systemImage: "checkmark.circle.fill")
                        .font(.hearthUI(12, weight: .medium))
                        .foregroundStyle(hearth.statusOK)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Ribbon(progress: episode.progressPercentage, tint: tint, height: 4)
            HStack {
                Text("\(Int(episode.progressPercentage * 100))% heard")
                Spacer()
                if let duration = episode.duration, duration > 0 {
                    Text(HearthFormat.remaining(duration - episode.currentTime))
                }
            }
            .font(.hearthUI(12))
            .foregroundStyle(hearth.textTertiary)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            EmberButton(
                title: episode.isStarted && !episode.isFinished ? "Resume" : "Play",
                systemImage: "play.fill",
                tint: tint
            ) {
                engine.playback.play(episode)
            }
            PodcastsDownloadControl(episode: episode, size: 48)
                .background {
                    Circle()
                        .fill(hearth.bgElevated)
                        .overlay(Circle().strokeBorder(hearth.hairline, lineWidth: 1))
                }
        }
    }

    private var metadataChips: some View {
        HStack(spacing: 8) {
            if let duration = episode.duration, duration > 0 {
                podcastsMetaChip(icon: "clock", text: HearthFormat.duration(duration))
            } else {
                podcastsMetaChip(icon: "clock", text: "Unknown length")
            }
            if isDownloaded {
                podcastsMetaChip(icon: "arrow.down.circle.fill", text: "Offline")
            }
            if episode.isFinished {
                podcastsMetaChip(icon: "checkmark", text: "Played")
            } else if episode.isStarted {
                podcastsMetaChip(icon: "play.fill", text: "\(Int(episode.progressPercentage * 100))%")
            }
        }
    }

    private func podcastsMetaChip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.hearthUI(11))
            Text(text)
                .font(.hearthUI(12, weight: .medium))
        }
        .foregroundStyle(hearth.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            Capsule()
                .fill(hearth.bgElevated)
                .overlay(Capsule().strokeBorder(hearth.hairline, lineWidth: 1))
        }
    }

    private func notesSection(_ raw: String) -> some View {
        let cleaned = PodcastsFormat.cleanHTML(raw)
        return VStack(alignment: .leading, spacing: 10) {
            Overline("Episode notes")
            Text(cleaned)
                .font(.hearthUI(14))
                .foregroundStyle(hearth.textSecondary)
                .lineSpacing(3)
                .lineLimit(notesExpanded ? nil : 6)
            if cleaned.count > 200 {
                Button {
                    withAnimation(.smooth(duration: 0.35)) { notesExpanded.toggle() }
                } label: {
                    Text(notesExpanded ? "Show less" : "Show more")
                        .font(.hearthUI(13, weight: .medium))
                        .foregroundStyle(hearth.ember)
                }
            }
        }
    }

    private func showFooter(_ showName: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle()
                .fill(hearth.hairline)
                .frame(height: 1)
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.hearthUI(13))
                    .foregroundStyle(hearth.ember)
                Text(showName)
                    .font(.hearthUI(14, weight: .medium))
                    .foregroundStyle(hearth.text)
                Spacer()
            }
        }
    }
}
