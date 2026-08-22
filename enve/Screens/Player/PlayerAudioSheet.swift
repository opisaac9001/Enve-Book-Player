import Combine
import SwiftUI

struct PlayerAudioSheet: View {
    let tint: Color

    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(\.hearth) private var hearth

    @ObservedObject private var audioProcessor = AudioProcessor.shared
    @State private var voiceBoostMode: VoiceBoostMode = .off
    @State private var savedCustomBands: [EqualizerBand]?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Overline("Audio")
                    .padding(.top, 28)
                voiceSection
                volumeLevelingSection
                equalizerSection
                outputSection
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .onAppear { voiceBoostMode = audioProcessor.voiceBoostMode }
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Overline("Voice")
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(BasicVoiceMode.allCases) { mode in
                        PlayerAudioChip(
                            title: mode.displayName,
                            isSelected: playerVM.preferences.basicVoiceMode == mode,
                            tint: tint
                        ) {
                            playerVM.setBasicVoiceMode(mode)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            Text(playerVM.preferences.basicVoiceMode.description)
                .font(.hearthUI(12))
                .foregroundStyle(hearth.textTertiary)

            Toggle(
                isOn: Binding(
                    get: { voiceBoostMode != .off },
                    set: { enabled in
                        setVoiceBoost(enabled ? .medium : .off)
                        playerVM.setVoiceBoostEnabled(enabled)
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Voice boost")
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                    Text("Shapes the sound toward the narrator's voice.")
                        .font(.hearthUI(12))
                        .foregroundStyle(hearth.textTertiary)
                }
            }
            .tint(tint)
            .padding(.top, 4)

            if voiceBoostMode != .off {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach([VoiceBoostMode.low, .medium, .high], id: \.self) { mode in
                            PlayerAudioChip(
                                title: mode.label,
                                isSelected: voiceBoostMode == mode,
                                tint: tint
                            ) {
                                setVoiceBoost(mode)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func setVoiceBoost(_ mode: VoiceBoostMode) {
        voiceBoostMode = mode
        audioProcessor.voiceBoostMode = mode
    }

    private var volumeLevelingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Overline("Volume leveling")
            Text("Evens out loud and quiet passages without changing playback speed.")
                .font(.hearthUI(12))
                .foregroundStyle(hearth.textTertiary)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(VolumeLevelingStrength.allCases) { strength in
                        PlayerAudioChip(
                            title: strength.displayName,
                            isSelected: audioProcessor.volumeLevelingStrength == strength,
                            tint: tint
                        ) {
                            audioProcessor.setVolumeLevelingStrength(strength)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var equalizerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(
                isOn: Binding(
                    get: { playerVM.preferences.eqEnabled },
                    set: { enabled in
                        playerVM.setEQEnabled(enabled)
                        if enabled {
                            if audioProcessor.currentEQPresetID == "custom", let saved = savedCustomBands {
                                audioProcessor.updateBands(saved)
                            } else {
                                audioProcessor.applyPreset(id: audioProcessor.currentEQPresetID)
                            }
                        } else {
                            if audioProcessor.currentEQPresetID == "custom" {
                                savedCustomBands = audioProcessor.bands
                            }
                            audioProcessor.updateBands(EqualizerPreset.flat.bands)
                        }
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    Overline("Equalizer")
                    Text("Five bands, applied to playback on this device.")
                        .font(.hearthUI(12))
                        .foregroundStyle(hearth.textTertiary)
                }
            }
            .tint(tint)

            if playerVM.preferences.eqEnabled {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(EqualizerPreset.allPresets) { preset in
                            PlayerAudioChip(
                                title: preset.name,
                                isSelected: audioProcessor.currentEQPresetID == preset.id,
                                tint: tint
                            ) {
                                audioProcessor.currentEQPresetID = preset.id
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)

                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(audioProcessor.bands.indices, id: \.self) { index in
                        eqBar(index: index)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.top, 6)

                QuietButton(title: "Reset to flat") {
                    PlatformHaptics.selection()
                    audioProcessor.currentEQPresetID = "flat"
                }
                .opacity(audioProcessor.currentEQPresetID == "flat" ? 0.4 : 1)
                .disabled(audioProcessor.currentEQPresetID == "flat")
            }
        }
    }

    private func eqBar(index: Int) -> some View {
        let band = audioProcessor.bands[index]
        return VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Capsule()
                        .fill(hearth.hairline)
                        .frame(width: 6)
                    Capsule()
                        .fill(tint)
                        .frame(width: 6, height: max(6, geo.size.height * CGFloat((band.gain + 12) / 24)))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let normalized = 1 - min(max(value.location.y / geo.size.height, 0), 1)
                            setBand(index, gain: Float(normalized * 24 - 12))
                        }
                )
            }
            .frame(height: 120)
            Text(band.label)
                .font(.hearthUI(10, weight: .medium))
                .foregroundStyle(hearth.textTertiary)
            Text("\(Int(band.gain.rounded()))")
                .font(.hearthUI(10).monospacedDigit())
                .foregroundStyle(hearth.textTertiary.opacity(0.8))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(band.label) band")
        .accessibilityValue("\(Int(band.gain.rounded())) decibels")
    }

    private func setBand(_ index: Int, gain: Float) {
        if audioProcessor.currentEQPresetID != "custom" {
            audioProcessor.currentEQPresetID = "custom"
        }
        var bands = audioProcessor.bands
        bands[index].gain = min(max(gain, -12), 12)
        audioProcessor.updateBands(bands)
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Overline("Output")

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Pitch")
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                    Spacer()
                    Text(pitchLabel)
                        .font(.hearthUI(13).monospacedDigit())
                        .foregroundStyle(hearth.textSecondary)
                }
                Slider(
                    value: Binding(
                        get: { playerVM.preferences.independentPitchSemitones },
                        set: { playerVM.setIndependentPitchSemitones($0) }
                    ),
                    in: -12...12,
                    step: 0.5
                )
                .tint(tint)
                .accessibilityLabel("Pitch in semitones")
            }
            .disabled(!playerVM.supportsIndependentPitch)
            .opacity(playerVM.supportsIndependentPitch ? 1 : 0.5)

            Toggle(
                isOn: Binding(
                    get: { playerVM.preferences.monoMixEnabled },
                    set: { playerVM.setMonoMixEnabled($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mono mix")
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                    Text("Folds both channels into one.")
                        .font(.hearthUI(12))
                        .foregroundStyle(hearth.textTertiary)
                }
            }
            .tint(tint)
            .disabled(!playerVM.supportsMonoMix)
            .opacity(playerVM.supportsMonoMix ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Balance")
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                    Spacer()
                    Text(balanceLabel)
                        .font(.hearthUI(13).monospacedDigit())
                        .foregroundStyle(hearth.textSecondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(playerVM.preferences.stereoBalance) },
                        set: { playerVM.setStereoBalance(Float($0)) }
                    ),
                    in: -1...1,
                    step: 0.05
                )
                .tint(tint)
                .accessibilityLabel("Stereo balance")
            }
            .disabled(!playerVM.supportsStereoBalance)
            .opacity(playerVM.supportsStereoBalance ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Noise reduction")
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                    Spacer()
                    Text("\(Int((playerVM.preferences.noiseReductionLevel * 100).rounded()))%")
                        .font(.hearthUI(13).monospacedDigit())
                        .foregroundStyle(hearth.textSecondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(playerVM.preferences.noiseReductionLevel) },
                        set: { playerVM.setNoiseReductionLevel(Float($0)) }
                    ),
                    in: 0...1
                )
                .tint(tint)
                .accessibilityLabel("Noise reduction level")
            }
            .disabled(!playerVM.supportsNoiseReduction)
            .opacity(playerVM.supportsNoiseReduction ? 1 : 0.5)

            Toggle(
                isOn: Binding(
                    get: { playerVM.preferences.binauralEnabled },
                    set: { playerVM.setBinauralEnabled($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Binaural")
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.text)
                    Text("Headphone spatial audio arrives with a later engine update.")
                        .font(.hearthUI(12))
                        .foregroundStyle(hearth.textTertiary)
                }
            }
            .tint(tint)
            .disabled(!playerVM.supportsBinauralAudio)
            .opacity(playerVM.supportsBinauralAudio ? 1 : 0.5)
        }
    }

    private var pitchLabel: String {
        let value = playerVM.preferences.independentPitchSemitones
        if abs(value) < 0.01 { return "Natural" }
        return String(format: "%+.1f st", value)
    }

    private var balanceLabel: String {
        let value = playerVM.preferences.stereoBalance
        if abs(value) < 0.026 { return "Centered" }
        return value < 0
            ? String(format: "Left %.0f%%", abs(value) * 100)
            : String(format: "Right %.0f%%", value * 100)
    }
}

struct PlayerAudioChip: View {
    let title: String
    let isSelected: Bool
    let tint: Color
    let action: () -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        Button {
            PlatformHaptics.selection()
            action()
        } label: {
            Text(title)
                .font(.hearthUI(13, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? hearth.onEmber : hearth.textSecondary)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background {
                    if isSelected {
                        Capsule().fill(tint)
                    } else {
                        Capsule()
                            .fill(hearth.bg)
                            .overlay(Capsule().strokeBorder(hearth.hairline, lineWidth: 1))
                    }
                }
        }
        .buttonStyle(PressableStyle())
    }
}
