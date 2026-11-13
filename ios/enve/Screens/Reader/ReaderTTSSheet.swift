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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader-tts-sheet")
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

                if let message = tts.speechError {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.ember)
                        .accessibilityIdentifier("reader-tts-error")
                }

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
                    Slider(value: $tts.rate, in: EbookTTSService.rateRange, step: 0.25) { isEditing in
                        if !isEditing { tts.commitRate() }
                    }
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
                .accessibilityValue(tts.currentVoiceDisplayName)

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
    @Environment(\.scenePhase) private var scenePhase
    @State private var preview: NarratorVoicePreview

    init(tts: EbookTTSService, onBack: @escaping () -> Void) {
        self.tts = tts
        self.onBack = onBack
        _preview = State(initialValue: NarratorVoicePreview(models: tts.models))
    }

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

            if preview.phase != .idle {
                sampleStatus
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            List {
                Section {
                    ForEach(EbookTTSEngineChoice.allCases) { engine in
                        voiceRow(
                            title: engine.displayName,
                            subtitle: engine.detail,
                            isSelected: tts.engineChoice == engine,
                            sample: tts.models.isReady(engine) ? currentSample(for: engine) : nil,
                            identifier: "tts-engine-\(engine.rawValue)"
                        ) {
                            tts.setEngineChoice(engine)
                        }
                    }
                } header: {
                    Overline("Engine")
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(hearth.hairline)

                ForEach(EbookTTSEngineChoice.downloadableCases) { engine in
                    Section {
                        NarratorModelControls(engine: engine, models: tts.models) { tts.downloadModel(for: engine) }
                            .padding(.vertical, 4)
                    } footer: {
                        if let license = engine.license, tts.downloadState(for: engine) != .ready {
                            Link(license.title, destination: license.url)
                                .font(.hearthCaption)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(hearth.hairline)
                }

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
                            isSelected: tts.selectedVoiceIdentifier == nil,
                            sample: .apple(voiceIdentifier: tts.recommendedVoice()?.identifier, language: tts.narrationLanguageCode)
                        ) {
                            tts.setVoice(nil)
                        }
                        ForEach(filteredVoices, id: \.identifier) { voice in
                            voiceRow(
                                title: voice.name,
                                subtitle: voiceSubtitle(for: voice),
                                isSelected: tts.selectedVoiceIdentifier == voice.identifier,
                                sample: .apple(voiceIdentifier: voice.identifier, language: voice.language.code.bcp47)
                            ) {
                                tts.setVoice(voice.identifier)
                            }
                        }
                    case .kokoro:
                        ForEach(KokoroTTSVoice.allCases) { voice in
                            voiceRow(
                                title: voice.displayName,
                                subtitle: voice.detail,
                                isSelected: tts.kokoroVoice == voice,
                                sample: .kokoro(voice),
                                identifier: "kokoro-voice-\(voice.rawValue)"
                            ) {
                                tts.setKokoroVoice(voice)
                            }
                        }
                    case .pocket:
                        HStack(spacing: 10) {
                            Text("Alba MacKenna")
                                .font(.hearthUI(15, weight: .medium))
                                .foregroundStyle(hearth.text)
                            Spacer()
                            sampleButton(.pocket, title: "Alba MacKenna")
                        }
                    case .phonon:
                        ForEach(PhononVoice.allCases) { voice in
                            voiceRow(
                                title: voice.rawValue,
                                subtitle: "British English",
                                isSelected: tts.phononVoice == voice,
                                sample: .phonon(voice),
                                identifier: "phonon-voice-\(voice.rawValue)"
                            ) {
                                tts.setPhononVoice(voice)
                            }
                        }
                    case .supertonic3:
                        ForEach(EnhancedTTSVoice.allCases) { voice in
                            voiceRow(
                                title: voice.displayName,
                                subtitle: voice.detail,
                                isSelected: tts.enhancedVoice == voice,
                                sample: .supertonic(voice, language: supertonicSampleLanguage),
                                identifier: "supertonic-voice-\(voice.rawValue)"
                            ) {
                                tts.setEnhancedVoice(voice)
                            }
                        }
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
        .task { await tts.models.refreshStorage() }
        .onDisappear { preview.invalidate() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { preview.stop() }
        }
        .onChange(of: tts.isPlaying) { _, playing in
            if playing { preview.stop() }
        }
        .onChange(of: tts.engineChoice) { _, _ in preview.stop() }
    }

    private var sampleStatus: some View {
        HStack(spacing: 12) {
            Group {
                switch preview.phase {
                case .idle:
                    EmptyView()
                case .preparing(let sample):
                    Label {
                        Text("Preparing sample · \(sample.displayName)")
                    } icon: {
                        ProgressView().tint(hearth.ember)
                    }
                    .foregroundStyle(hearth.textSecondary)
                case .playing(let sample):
                    Label("Playing sample · \(sample.displayName)", systemImage: "waveform")
                        .foregroundStyle(hearth.text)
                case .failed(_, let message):
                    Label(message, systemImage: "exclamationmark.circle")
                        .foregroundStyle(hearth.statusError)
                }
            }
            .font(.hearthCaption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("tts-sample-status")

            if case .failed = preview.phase {
                GlyphButton(systemImage: "xmark", size: 34, glyphSize: 12, label: "Dismiss") { preview.stop() }
            } else {
                QuietButton(title: "Stop sample", systemImage: "stop.fill") { preview.stop() }
                    .accessibilityIdentifier("tts-sample-stop")
            }
        }
    }

    private func currentSample(for engine: EbookTTSEngineChoice) -> NarratorVoiceSample {
        switch engine {
        case .apple:
            .apple(
                voiceIdentifier: tts.selectedVoiceIdentifier ?? tts.recommendedVoice()?.identifier,
                language: tts.narrationLanguageCode
            )
        case .kokoro: .kokoro(tts.kokoroVoice)
        case .supertonic3: .supertonic(tts.enhancedVoice, language: supertonicSampleLanguage)
        case .pocket: .pocket
        case .phonon: .phonon(tts.phononVoice)
        }
    }

    private var supertonicSampleLanguage: String {
        let language = tts.narrationLanguageCode
        return EnhancedTTSVoice.supportedLanguageCodes.contains(language) ? language : "en"
    }

    private var automaticSubtitle: String {
        guard let recommended = tts.recommendedVoice() else {
            return tts.currentLanguageDisplayName
        }
        return "\(recommended.name) · \(tts.currentLanguageDisplayName)"
    }

    private func voiceRow(
        title: String,
        subtitle: String?,
        isSelected: Bool,
        sample: NarratorVoiceSample? = nil,
        identifier: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Button {
                PlatformHaptics.selection()
                preview.stop()
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
            // A non-default style keeps List from routing the sample button's taps to this row.
            .buttonStyle(PressableStyle())
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier(identifier ?? "")

            if let sample { sampleButton(sample, title: title) }
        }
    }

    private func sampleButton(_ sample: NarratorVoiceSample, title: String) -> some View {
        let isActive = preview.isActive(sample)
        return GlyphButton(
            systemImage: isActive ? "stop.fill" : "speaker.wave.2",
            size: 44,
            glyphSize: 13,
            label: isActive ? "Stop sample" : "Play sample of \(title)"
        ) {
            if isActive {
                preview.stop()
            } else {
                preview.play(sample, rate: tts.rate, pausing: tts)
            }
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
