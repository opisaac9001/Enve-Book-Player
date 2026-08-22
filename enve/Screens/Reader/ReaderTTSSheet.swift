import Combine
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared
import SwiftUI

struct ReaderTTSSheet: View {
    @ObservedObject var tts: EbookTTSService

    let onStartFromCurrentPosition: () -> Void

    @Environment(\.hearth) private var hearth
    @State private var showingVoices = false

    init(tts: EbookTTSService, onStartFromCurrentPosition: @escaping () -> Void) {
        self.tts = tts
        self.onStartFromCurrentPosition = onStartFromCurrentPosition
        _showingVoices = State(
            initialValue: [
                "ttsvoices", "ttsdownload", "ttsplayback", "kokorodownload", "kokoroplayback",
            ].contains(Self.debugRoute)
        )
    }

    var body: some View {
        Group {
            if showingVoices {
                ReaderVoicePicker(tts: tts) {
                    withAnimation(.smooth(duration: 0.25)) { showingVoices = false }
                }
            } else {
                controls
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(hearth.bg)
        .hearthPresentationBackground()
        .task {
            switch Self.debugRoute {
            case "ttsdownload", "ttsplayback":
                tts.setEngineChoice(.supertonic3)
            case "kokorodownload", "kokoroplayback":
                tts.setEngineChoice(.kokoro)
            default:
                break
            }
        }
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Overline("Read to me")

                if !tts.currentUtteranceText.isEmpty {
                    Text(tts.currentUtteranceText)
                        .font(.hearthDisplay(16, weight: .regular))
                        .foregroundStyle(hearth.text)
                        .lineLimit(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background {
                            RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                                .fill(hearth.bgElevated)
                                .overlay {
                                    RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                                        .strokeBorder(hearth.hairline, lineWidth: 1)
                                }
                        }
                }

                HStack(spacing: 28) {
                    Spacer()
                    GlyphButton(systemImage: "backward.fill", size: 48, glyphSize: 16, label: "Previous paragraph") {
                        tts.previousParagraph()
                    }
                    .disabled(!tts.isPlaying && !tts.isPaused)
                    .opacity(tts.isPlaying || tts.isPaused ? 1 : 0.4)
                    GlyphButton(
                        systemImage: tts.isPlaying ? "pause.fill" : "play.fill",
                        size: 68,
                        glyphSize: 24,
                        prominent: true,
                        label: tts.isPlaying ? "Pause" : "Read aloud"
                    ) {
                        if tts.isPlaying {
                            tts.pause()
                        } else if tts.isPaused {
                            tts.resume()
                        } else {
                            onStartFromCurrentPosition()
                        }
                    }
                    GlyphButton(systemImage: "forward.fill", size: 48, glyphSize: 16, label: "Next paragraph") {
                        tts.nextParagraph()
                    }
                    .disabled(!tts.isPlaying && !tts.isPaused)
                    .opacity(tts.isPlaying || tts.isPaused ? 1 : 0.4)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Pace")
                            .font(.hearthUI(15, weight: .medium))
                            .foregroundStyle(hearth.text)
                        Spacer()
                        Text(String(format: "%.2f×", tts.rate))
                            .font(.hearthUI(14, weight: .medium).monospacedDigit())
                            .foregroundStyle(hearth.textSecondary)
                    }
                    Slider(value: $tts.rate, in: 0.5...3.0, step: 0.25)
                        .tint(hearth.ember)
                }

                Button {
                    withAnimation(.smooth(duration: 0.25)) { showingVoices = true }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "person.wave.2")
                            .font(.hearthUI(15, weight: .medium))
                            .foregroundStyle(hearth.ember)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tts.currentVoiceDisplayName)
                                .font(.hearthUI(15, weight: .medium))
                                .foregroundStyle(hearth.text)
                            Text(tts.currentLanguageDisplayName)
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.hearthUI(12, weight: .semibold))
                            .foregroundStyle(hearth.textTertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background {
                        RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                            .fill(hearth.bgElevated)
                            .overlay {
                                RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                                    .strokeBorder(hearth.hairline, lineWidth: 1)
                            }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Choose a voice")

                if tts.isPlaying || tts.isPaused {
                    QuietButton(title: "Stop reading", systemImage: "stop.fill") {
                        tts.stop()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 26)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
    }

    private static var debugRoute: String? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-imagineScreen"),
            arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
        #else
        return nil
        #endif
    }
}

private struct ReaderVoicePicker: View {
    @ObservedObject var tts: EbookTTSService
    let onBack: () -> Void

    @Environment(\.hearth) private var hearth

    private var selectedLanguage: Language {
        if let preferred = tts.preferredLanguageIdentifier {
            return Language(code: .bcp47(preferred))
        }
        if let selectedId = tts.selectedVoiceIdentifier,
            let voice = tts.voiceWithIdentifier(selectedId)
        {
            return voice.language.removingRegion()
        }
        if let recommended = tts.recommendedVoice() {
            return recommended.language.removingRegion()
        }
        return tts.availableLanguages.first ?? .current
    }

    private var filteredVoices: [TTSVoice] {
        tts.availableVoices
            .filterByLanguage(selectedLanguage)
            .sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                GlyphButton(systemImage: "chevron.left", size: 38, glyphSize: 14, label: "Back") { onBack() }
                Overline("Voices")
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 6)

            List {
                Section {
                    ForEach(EbookTTSEngineChoice.allCases) { engine in
                        voiceRow(
                            title: engine.displayName,
                            subtitle: engine.detail,
                            isSelected: tts.engineChoice == engine
                        ) {
                            tts.setEngineChoice(engine)
                        }
                    }
                } header: {
                    Overline("Engine")
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(hearth.hairline)

                modelDownloadSection(for: .supertonic3)
                modelDownloadSection(for: .kokoro)

                Section {
                    voiceRow(
                        title: "The book's language",
                        subtitle: tts.bookLanguageDisplayName,
                        isSelected: tts.preferredLanguageIdentifier == nil
                    ) {
                        tts.setPreferredLanguage(nil)
                    }
                    ForEach(tts.availableLanguages, id: \.code.bcp47) { language in
                        voiceRow(
                            title: language.removingRegion().localizedDescription(),
                            subtitle: nil,
                            isSelected: tts.preferredLanguageIdentifier == language.code.bcp47
                        ) {
                            tts.setPreferredLanguage(language.code.bcp47)
                        }
                    }
                } header: {
                    Overline("Language")
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(hearth.hairline)

                Section {
                    switch tts.engineChoice {
                    case .apple:
                        voiceRow(
                            title: "Automatic",
                            subtitle: automaticSubtitle,
                            isSelected: tts.selectedVoiceIdentifier == nil
                        ) {
                            tts.setVoice(nil)
                        }
                        ForEach(filteredVoices, id: \.identifier) { voice in
                            voiceRow(
                                title: voice.name,
                                subtitle: voiceSubtitle(for: voice),
                                isSelected: tts.selectedVoiceIdentifier == voice.identifier
                            ) {
                                tts.setVoice(voice.identifier)
                            }
                        }
                    case .supertonic3:
                        ForEach(EnhancedTTSVoice.allCases) { voice in
                            voiceRow(
                                title: voice.displayName,
                                subtitle: voice.detail,
                                isSelected: tts.enhancedVoice == voice
                            ) {
                                tts.setEnhancedVoice(voice)
                            }
                        }
                    case .kokoro:
                        voiceRow(
                            title: "Heart",
                            subtitle: "American English · feminine",
                            isSelected: true,
                            action: {}
                        )
                    }
                } header: {
                    Overline("Voice")
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(hearth.hairline)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private func modelDownloadSection(for engine: EbookTTSEngineChoice) -> some View {
        switch tts.downloadState(for: engine) {
        case .notDownloaded:
            Section {
                downloadRow(for: engine, title: engine.downloadTitle)
            } footer: {
                Text("Download once; narration stays private and works offline afterward.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
            }
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(hearth.hairline)
        case .downloading(let progress):
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Downloading \(engine.modelName)")
                            .font(.hearthUI(15, weight: .medium))
                            .foregroundStyle(hearth.text)
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.hearthCaption.monospacedDigit())
                            .foregroundStyle(hearth.textSecondary)
                    }
                    ProgressView(value: progress)
                        .tint(hearth.ember)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(hearth.hairline)
        case .removing:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                        .tint(hearth.ember)
                    Text("Removing \(engine.modelName)")
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(hearth.hairline)
        case .failed(let message):
            Section {
                downloadRow(for: engine, title: "Try \(engine.modelName) again")
            } footer: {
                Text(message)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
            }
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(hearth.hairline)
        case .ready:
            Section {
                Button(role: .destructive) {
                    tts.removeModel(for: engine)
                } label: {
                    HStack {
                        Text("Remove \(engine.modelName) download")
                            .font(.hearthUI(15, weight: .medium))
                        Spacer()
                        Image(systemName: "trash")
                            .font(.hearthUI(15, weight: .medium))
                    }
                    .contentShape(Rectangle())
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(hearth.hairline)
        }
    }

    private func downloadRow(for engine: EbookTTSEngineChoice, title: String) -> some View {
        Button {
            tts.downloadModel(for: engine)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.ember)
                    Text(engine.downloadDetail)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                Spacer()
                Image(systemName: "arrow.down.circle")
                    .font(.hearthUI(17, weight: .medium))
                    .foregroundStyle(hearth.ember)
            }
            .contentShape(Rectangle())
        }
    }

    private var automaticSubtitle: String {
        guard let recommended = tts.recommendedVoice() else {
            return tts.currentLanguageDisplayName
        }
        return "\(recommended.name) · \(tts.currentLanguageDisplayName)"
    }

    private func voiceRow(title: String, subtitle: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            PlatformHaptics.selection()
            action()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.hearthUI(13, weight: .semibold))
                        .foregroundStyle(hearth.ember)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
    }

    private func voiceSubtitle(for voice: TTSVoice) -> String {
        [voice.language.localizedRegion(), readerQualityLabel(voice.quality)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func readerQualityLabel(_ quality: TTSVoice.Quality?) -> String? {
        switch quality {
        case .higher: "Best"
        case .high: "High"
        case .medium: "Standard"
        case .low: "Basic"
        case .lower: "Lowest"
        case nil: nil
        }
    }
}
