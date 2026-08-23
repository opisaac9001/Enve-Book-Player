import SwiftUI

struct ReaderAnnotateBar: View {
    @Binding var selectedColor: String
    let onHighlight: (String) -> Void
    let onUnderline: () -> Void
    let onStrikethrough: () -> Void
    let onSquiggle: () -> Void
    let onNote: () -> Void
    let onCopy: () -> Void
    let onDefine: () -> Void

    @Environment(\.hearth) private var hearth

    private static let inks: [(hex: String, label: String)] = [
        ("#FFF59D", "Yellow highlight"),
        ("#A5D6A7", "Green highlight"),
        ("#90CAF9", "Blue highlight"),
        ("#F8BBD0", "Pink highlight"),
    ]

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 390
            HStack(spacing: compact ? 5 : 10) {
                selectedColorButton(compact: compact)
                colorMenu(compact: compact)

                Rectangle()
                    .fill(hearth.hairline)
                    .frame(width: 1, height: compact ? 20 : 22)

                barGlyph("square.and.pencil", label: "Note", compact: compact, action: onNote)
                barGlyph("doc.on.doc", label: "Copy", compact: compact, action: onCopy)
                barGlyph("character.book.closed", label: "Define", compact: compact, action: onDefine)
                styleMenu(compact: compact)
            }
            .padding(.horizontal, compact ? 9 : 14)
            .padding(.vertical, compact ? 8 : 10)
            .frame(maxWidth: proxy.size.width - 28)
            .background {
                HearthChromeBackground(
                    shape: .capsule,
                    fill: hearth.bgElevated,
                    stroke: hearth.hairline,
                    tint: hearth.bgElevated,
                    shadow: true
                )
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(height: 54)
    }

    private func selectedColorButton(compact: Bool) -> some View {
        Button {
            onHighlight(selectedColor)
        } label: {
            Circle()
                .fill(Color(legacyHexString: selectedColor) ?? .yellow)
                .frame(width: compact ? 23 : 26, height: compact ? 23 : 26)
                .overlay {
                    Circle().strokeBorder(hearth.text, lineWidth: 2)
                }
                .frame(width: compact ? 32 : 38, height: compact ? 32 : 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(currentColorLabel)
    }

    private func colorMenu(compact: Bool) -> some View {
        Menu {
            ForEach(Self.inks, id: \.hex) { ink in
                Button {
                    selectedColor = ink.hex
                    onHighlight(ink.hex)
                } label: {
                    Label {
                        Text(ink.label)
                    } icon: {
                        Circle()
                            .fill(Color(legacyHexString: ink.hex) ?? .yellow)
                    }
                }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(
                        AngularGradient(
                            colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red],
                            center: .center
                        )
                    )
                    .frame(width: compact ? 23 : 26, height: compact ? 23 : 26)
                Circle()
                    .strokeBorder(hearth.hairline, lineWidth: 1)
                    .frame(width: compact ? 23 : 26, height: compact ? 23 : 26)
            }
            .frame(width: compact ? 32 : 38, height: compact ? 32 : 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Highlight colors")
    }

    private func styleMenu(compact: Bool) -> some View {
        Menu {
            Button(action: onUnderline) {
                Label("Underline", systemImage: "underline")
            }
            Button(action: onStrikethrough) {
                Label("Strikethrough", systemImage: "strikethrough")
            }
            Button(action: onSquiggle) {
                Label("Squiggle", systemImage: "scribble.variable")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.hearthUI(compact ? 15 : 17, weight: .medium))
                .foregroundStyle(hearth.text)
                .frame(width: compact ? 27 : 31, height: compact ? 31 : 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("More annotation styles")
    }

    private var currentColorLabel: String {
        Self.inks.first(where: { $0.hex == selectedColor })?.label ?? "Highlight"
    }

    private func barGlyph(_ systemImage: String, label: String, compact: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.hearthUI(compact ? 14 : 16, weight: .medium))
                .foregroundStyle(hearth.text)
                .frame(width: compact ? 27 : 31, height: compact ? 31 : 34)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }
}

struct ReaderNoteSheet: View {
    var title = "A note in the margin"
    var actionTitle = "Keep it"
    let excerpt: String
    let onSave: (String?) -> Void

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Overline(title)

            if !excerpt.isEmpty {
                Text(excerpt)
                    .font(.hearthDisplay(16, weight: .regular))
                    .italic()
                    .foregroundStyle(hearth.textSecondary)
                    .lineLimit(3)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(hearth.ember)
                            .frame(width: 2)
                    }
            }

            TextField("", text: $note, prompt: Text("Write something…").font(.hearthDisplay(16, weight: .regular)), axis: .vertical)
                .font(.hearthUI(16))
                .foregroundStyle(hearth.text)
                .focused($fieldFocused)
                .lineLimit(3...6)
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                        .fill(hearth.bgElevated)
                        .overlay {
                            RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                                .strokeBorder(hearth.hairline, lineWidth: 1)
                        }
                }

            HStack {
                Spacer()
                EmberButton(title: actionTitle) {
                    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(trimmed.isEmpty ? nil : trimmed)
                    dismiss()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(hearth.bg)
        .hearthPresentationBackground()
        .onAppear { fieldFocused = true }
    }
}
