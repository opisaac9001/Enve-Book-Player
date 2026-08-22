import SwiftUI
import UIKit

struct PlayerClipDraft: Identifiable {
    let id = UUID()
    let bookmark: Bookmark?
    let clip: AudiobookClip?
    let anchorTime: TimeInterval
    let bookDuration: TimeInterval
}

struct PlayerClipEditorSheet: View {
    let draft: PlayerClipDraft
    let tint: Color
    let onSave: (TimeInterval, TimeInterval, String, String?) -> Void

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var backwardSeconds: Double
    @State private var forwardSeconds: Double
    @State private var title: String
    @State private var note: String

    init(draft: PlayerClipDraft, tint: Color, onSave: @escaping (TimeInterval, TimeInterval, String, String?) -> Void) {
        self.draft = draft
        self.tint = tint
        self.onSave = onSave

        let existingBackward = max(0, draft.anchorTime - (draft.clip?.startTime ?? draft.anchorTime))
        let existingForward = max(0, (draft.clip?.endTime ?? min(draft.bookDuration, draft.anchorTime + 60)) - draft.anchorTime)
        _backwardSeconds = State(initialValue: existingBackward)
        _forwardSeconds = State(initialValue: existingForward)
        _title = State(initialValue: draft.bookmark?.title ?? "")
        _note = State(initialValue: draft.bookmark?.note ?? "")
    }

    private var maxBackward: Double { min(draft.anchorTime, 3600) }
    private var maxForward: Double { min(max(0, draft.bookDuration - draft.anchorTime), 3600) }
    private var clipStart: TimeInterval { max(0, draft.anchorTime - backwardSeconds) }
    private var clipEnd: TimeInterval { min(draft.bookDuration, draft.anchorTime + forwardSeconds) }
    private var clipDuration: TimeInterval { max(0, clipEnd - clipStart) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Overline(draft.clip == nil ? "New clip" : "Edit clip")
                    Spacer()
                    Button {
                        PlatformHaptics.notification(.success)
                        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(clipStart, clipEnd, trimmedTitle, trimmedNote.isEmpty ? nil : trimmedNote)
                        dismiss()
                    } label: {
                        Text("Save")
                            .font(.hearthUI(14, weight: .semibold))
                            .foregroundStyle(hearth.onEmber)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(tint, in: Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(clipDuration <= 0)
                    .opacity(clipDuration <= 0 ? 0.4 : 1)
                }
                .padding(.top, 28)

                VStack(alignment: .leading, spacing: 12) {
                    Overline("Bookmark")
                    playerClipField("Title", text: $title)
                    playerClipField("Note", text: $note, axis: .vertical)
                    HStack {
                        Text("Anchored at")
                            .font(.hearthUI(13, weight: .medium))
                            .foregroundStyle(hearth.textSecondary)
                        Spacer()
                        Text(HearthFormat.clock(draft.anchorTime))
                            .font(.hearthUI(13).monospacedDigit())
                            .foregroundStyle(hearth.text)
                    }
                }

                VStack(alignment: .leading, spacing: 16) {
                    Overline("Reach")

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Starts")
                                .font(.hearthUI(13, weight: .medium))
                                .foregroundStyle(hearth.textSecondary)
                            Spacer()
                            Text(HearthFormat.clock(clipStart))
                                .font(.hearthUI(13).monospacedDigit())
                                .foregroundStyle(hearth.text)
                        }
                        Slider(value: $backwardSeconds, in: 0...max(maxBackward, 0.001), step: 1)
                            .tint(tint)
                            .accessibilityLabel("Seconds before the bookmark")
                            .onChange(of: backwardSeconds) { _, new in
                                if new + forwardSeconds > 3600 {
                                    forwardSeconds = max(0, 3600 - new)
                                }
                            }
                        Text(
                            backwardSeconds == 0
                                ? "Begins at the bookmark." : "Begins \(HearthFormat.clock(backwardSeconds)) before the bookmark."
                        )
                        .font(.hearthUI(11))
                        .foregroundStyle(hearth.textTertiary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Ends")
                                .font(.hearthUI(13, weight: .medium))
                                .foregroundStyle(hearth.textSecondary)
                            Spacer()
                            Text(HearthFormat.clock(clipEnd))
                                .font(.hearthUI(13).monospacedDigit())
                                .foregroundStyle(hearth.text)
                        }
                        Slider(value: $forwardSeconds, in: 0...max(maxForward, 0.001), step: 1)
                            .tint(tint)
                            .accessibilityLabel("Seconds after the bookmark")
                            .onChange(of: forwardSeconds) { _, new in
                                if backwardSeconds + new > 3600 {
                                    backwardSeconds = max(0, 3600 - new)
                                }
                            }
                        Text(
                            forwardSeconds == 0 ? "Ends at the bookmark." : "Ends \(HearthFormat.clock(forwardSeconds)) after the bookmark."
                        )
                        .font(.hearthUI(11))
                        .foregroundStyle(hearth.textTertiary)
                    }

                    HStack {
                        Text("Length")
                            .font(.hearthUI(13, weight: .medium))
                            .foregroundStyle(hearth.textSecondary)
                        Spacer()
                        Text(HearthFormat.clock(clipDuration))
                            .font(.hearthUI(13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(tint)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func playerClipField(_ placeholder: String, text: Binding<String>, axis: Axis = .horizontal) -> some View {
        Group {
            if axis == .vertical {
                TextField(placeholder, text: text, axis: .vertical)
                    .lineLimit(2...5)
            } else {
                TextField(placeholder, text: text)
            }
        }
        .font(.hearthUI(15))
        .foregroundStyle(hearth.text)
        .textFieldStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hearth.bg)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hearth.hairline, lineWidth: 1))
        }
    }
}

struct PlayerClipTranscriptSheet: View {
    let title: String
    let transcript: String

    @Environment(\.hearth) private var hearth

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Overline("Transcript")
                        Text(title)
                            .font(.hearthDisplay(18, weight: .semibold))
                            .foregroundStyle(hearth.text)
                            .lineLimit(2)
                    }
                    Spacer()
                    ShareLink(item: transcript) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.hearthUI(15, weight: .medium))
                            .foregroundStyle(hearth.text)
                            .frame(width: 44, height: 44)
                            .background {
                                Circle()
                                    .fill(hearth.bg)
                                    .overlay(Circle().strokeBorder(hearth.hairline, lineWidth: 1))
                            }
                    }
                    .accessibilityLabel("Share transcript")
                }
                .padding(.top, 28)

                Text(transcript)
                    .font(.hearthDisplay(16, weight: .regular))
                    .foregroundStyle(hearth.text)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
    }
}

struct PlayerSharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

struct PlayerShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
