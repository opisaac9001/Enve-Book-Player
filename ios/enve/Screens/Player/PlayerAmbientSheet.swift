import SwiftUI
import UniformTypeIdentifiers

struct PlayerAmbientSheet: View {
    let tint: Color

    @Environment(\.hearth) private var hearth

    @State private var showingImporter = false
    @State private var volume = AmbientAudioService.shared.currentVolume

    private var ambientAudio: AmbientAudioService { .shared }

    private static let importTypes: [UTType] = {
        var types: [UTType] = [.audio]
        for ext in ["mp3", "m4a", "m4b", "aac", "wav", "flac", "ogg", "opus"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Overline("Ambient sound")
                    .padding(.top, 28)

                if let selection = ambientAudio.currentSelection {
                    selectionCard(selection)
                } else {
                    Text(
                        "Lay a quiet sound under the narration. Use an included one, or any audio file of your own. It stays with this book and pauses when the book pauses."
                    )
                    .font(.hearthUI(13))
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                includedSounds
                bringYourOwn
                moreSounds
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: Self.importTypes) { result in
            switch result {
            case .success(let url):
                ambientAudio.attachTrackToCurrentBook(from: url)
            case .failure(let error):
                ambientAudio.errorMessage = "That file could not be imported: \(error.localizedDescription)"
            }
        }
        .alert("Ambient sound", isPresented: ambientAlertPresented) {
            Button("All right") { ambientAudio.clearError() }
        } message: {
            Text(ambientAudio.errorMessage ?? "")
        }
    }

    private func selectionCard(_ selection: AmbientAudioSelection) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: presetGlyph(for: selection))
                    .font(.hearthUI(17))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(selection.displayName)
                        .font(.hearthUI(15, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .lineLimit(1)
                    Text(ambientAudio.isPlaying ? "Playing softly behind the narration" : "Waiting with the narration")
                        .font(.hearthUI(12))
                        .foregroundStyle(hearth.textTertiary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Volume")
                        .font(.hearthUI(13, weight: .medium))
                        .foregroundStyle(hearth.textSecondary)
                    Spacer()
                    Text("\(Int((volume * 100).rounded()))%")
                        .font(.hearthUI(13).monospacedDigit())
                        .foregroundStyle(hearth.textSecondary)
                }
                Slider(value: $volume, in: 0...1)
                    .tint(tint)
                    .accessibilityLabel("Ambient volume")
                    .onChange(of: volume) { _, new in
                        ambientAudio.updateVolume(new)
                    }
            }

            HStack(spacing: 10) {
                QuietButton(title: "Replace") { showingImporter = true }
                Button {
                    PlatformHaptics.impact(.light)
                    ambientAudio.removeTrackFromCurrentBook()
                } label: {
                    Text("Remove")
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.statusError)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background {
                            Capsule()
                                .fill(hearth.bg)
                                .overlay(Capsule().strokeBorder(hearth.hairline, lineWidth: 1))
                        }
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint.opacity(0.1))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
        }
    }

    private func presetGlyph(for selection: AmbientAudioSelection) -> String {
        if let presetId = selection.presetId, let preset = AmbientAudioPresets.preset(id: presetId) {
            return preset.systemImage
        }
        return "waveform"
    }

    private var includedSounds: some View {
        VStack(alignment: .leading, spacing: 4) {
            Overline("Included sounds")
                .padding(.bottom, 8)
            ForEach(Array(AmbientAudioPresets.all.enumerated()), id: \.element.id) { index, preset in
                Button {
                    PlatformHaptics.selection()
                    ambientAudio.attachPresetToCurrentBook(preset)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: preset.systemImage)
                            .font(.hearthUI(15))
                            .foregroundStyle(tint)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title)
                                .font(.hearthUI(15, weight: .medium))
                                .foregroundStyle(hearth.text)
                            Text(preset.subtitle)
                                .font(.hearthUI(12))
                                .foregroundStyle(hearth.textTertiary)
                        }
                        Spacer()
                        if ambientAudio.currentSelection?.presetId == preset.id {
                            Image(systemName: "checkmark")
                                .font(.hearthUI(13, weight: .semibold))
                                .foregroundStyle(tint)
                        }
                    }
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())

                if index < AmbientAudioPresets.all.count - 1 {
                    Rectangle().fill(hearth.hairline).frame(height: 1)
                }
            }
        }
    }

    private var bringYourOwn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Overline("Your own sound")
            QuietButton(title: "Choose an audio file", systemImage: "folder") {
                showingImporter = true
            }
            Text("Anything from Files or iCloud Drive. It loops quietly under the book.")
                .font(.hearthUI(12))
                .foregroundStyle(hearth.textTertiary)
        }
    }

    private var moreSounds: some View {
        VStack(alignment: .leading, spacing: 10) {
            Overline("Find more")
            ambientLink("Mixkit rain sounds", url: "https://mixkit.co/free-sound-effects/rain/")
            ambientLink("Pixabay nature ambience", url: "https://pixabay.com/sound-effects/search/nature%20ambience/")
            ambientLink("Freesound CC0 search", url: "https://freesound.org/search/?q=rainforest&f=license:%22Creative%20Commons%200%22")
        }
    }

    private func ambientLink(_ title: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 9) {
                Image(systemName: "safari")
                    .font(.hearthUI(13))
                Text(title)
                    .font(.hearthUI(14, weight: .medium))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.hearthUI(11, weight: .semibold))
            }
            .foregroundStyle(hearth.textSecondary)
        }
    }

    private var ambientAlertPresented: Binding<Bool> {
        Binding(
            get: { ambientAudio.errorMessage != nil },
            set: { if !$0 { ambientAudio.clearError() } }
        )
    }
}
