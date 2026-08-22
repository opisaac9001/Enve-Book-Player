import SwiftUI

struct ReaderReadAloudTray: View {
    @ObservedObject var model: ClassicReaderModel

    @Environment(\.hearth) private var hearth
    private var highlightEnabled: Bool { model.appearance.readAloudHighlightEnabled }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 12) {
                    Overline("Highlight")
                    readerToggleRow(
                        title: "Follow the words",
                        caption: "Lights the text as it is read. Turn off to hear the audio while you read at your own pace.",
                        isOn: Binding(
                            get: { highlightEnabled },
                            set: { enabled in
                                guard enabled != highlightEnabled else { return }
                                model.toggleReadAloudHighlighting()
                            }
                        )
                    )

                    HStack(spacing: 8) {
                        ForEach(ReadAloudGranularityMode.allCases) { mode in
                            HearthChip(title: mode.label, isSelected: model.appearance.readAloudGranularityMode == mode) {
                                PlatformHaptics.selection()
                                model.appearance.readAloudGranularityMode = mode
                            }
                        }
                    }
                    .disabled(!highlightEnabled)
                    .opacity(highlightEnabled ? 1 : 0.45)
                    Text(model.appearance.readAloudGranularityMode.description)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                        .opacity(highlightEnabled ? 1 : 0.45)

                    HStack(spacing: 12) {
                        ForEach(ReadAloudHighlightColor.allCases) { color in
                            Button {
                                PlatformHaptics.selection()
                                model.appearance.readAloudHighlightColor = color
                            } label: {
                                Circle()
                                    .fill(color.swiftUIColor.opacity(0.55))
                                    .frame(width: 34, height: 34)
                                    .overlay {
                                        Circle()
                                            .strokeBorder(
                                                model.appearance.readAloudHighlightColor == color ? hearth.text : .clear,
                                                lineWidth: 2.5
                                            )
                                    }
                                    .frame(width: 44, height: 44)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityLabel("\(color.label) highlight")
                        }
                    }
                    .padding(.top, 2)
                    .disabled(!highlightEnabled)
                    .opacity(highlightEnabled ? 1 : 0.45)
                }

                VStack(alignment: .leading, spacing: 14) {
                    Overline("Timing")

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Sync offset")
                                .font(.hearthUI(15, weight: .medium))
                                .foregroundStyle(hearth.text)
                            Spacer()
                            Text(String(format: "%+.1fs", model.appearance.readAloudSyncOffset))
                                .font(.hearthUI(14, weight: .medium).monospacedDigit())
                                .foregroundStyle(hearth.textSecondary)
                        }
                        Slider(
                            value: Binding(
                                get: { model.appearance.readAloudSyncOffset },
                                set: { model.appearance.readAloudSyncOffset = $0 }
                            ),
                            in: -1.0...1.0,
                            step: 0.1
                        )
                        .tint(hearth.ember)
                        Text("Fine-tunes the highlight against the audio.")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Page-turn lead")
                                .font(.hearthUI(15, weight: .medium))
                                .foregroundStyle(hearth.text)
                            Spacer()
                            Text("\(model.appearance.readAloudPageTurnLeadMs) ms")
                                .font(.hearthUI(14, weight: .medium).monospacedDigit())
                                .foregroundStyle(hearth.textSecondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(model.appearance.readAloudPageTurnLeadMs) },
                                set: { model.appearance.readAloudPageTurnLeadMs = Int($0) }
                            ),
                            in: 0...1500,
                            step: 100
                        )
                        .tint(hearth.ember)
                        Text("Turns the page this far before the sentence ends, so the next page is already waiting.")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }

                    readerToggleRow(
                        title: "Skip audio on page turn",
                        caption: "When you turn the page yourself, Read Aloud moves to match.",
                        isOn: Binding(
                            get: { model.appearance.readAloudSkipOnPageTurn },
                            set: { model.appearance.readAloudSkipOnPageTurn = $0 }
                        )
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 26)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(hearth.bg)
        .hearthPresentationBackground()
    }

    private func readerToggleRow(title: String, caption: String, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: isOn) {
                Text(title)
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.text)
            }
            .tint(hearth.ember)
            Text(caption)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
        }
    }
}
