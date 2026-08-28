import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ReaderAppearanceTray: View {
    @ObservedObject var model: ClassicReaderModel

    @Environment(\.hearth) private var hearth
    private let fontLibrary = ReaderFontLibrary.shared
    @State private var installingFontId: String?
    @State private var showingFontImporter = false
    @State private var fontError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                switch model.state {
                case .readyComic:
                    comicControls
                case .readyPDF:
                    flowControls
                default:
                    epubControls
                }
                nextSeriesControls
            }
            .padding(.horizontal, 20)
            .padding(.top, 26)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(hearth.bg)
        .hearthPresentationBackground()
        .onAppear { fontLibrary.loadInstalledFonts() }
        .fileImporter(isPresented: $showingFontImporter, allowedContentTypes: [.font]) { result in
            do {
                let url = try result.get()
                let installed = try fontLibrary.importFontFile(from: url)
                model.appearance.customFontFamilyName = installed.familyName
                model.appearance.usesCustomFont = true
            } catch {
                fontError = error.localizedDescription
            }
        }
        .alert(
            "That font wouldn't come in.",
            isPresented: Binding(
                get: { fontError != nil },
                set: { if !$0 { fontError = nil } }
            )
        ) {
            Button("All right", role: .cancel) {}
        } message: {
            Text(fontError ?? "")
        }
    }

    @ViewBuilder
    private var epubControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Overline("Theme")
            readerToggle(
                "Follow system appearance",
                isOn: Binding(
                    get: { model.appearance.themeMode == .automatic },
                    set: {
                        PlatformHaptics.selection()
                        model.appearance.themeMode = $0 ? .automatic : .fixed
                    }
                )
            )

            if model.appearance.themeMode == .automatic {
                VStack(spacing: 8) {
                    ReaderAutomaticThemeRow(
                        title: "Light mode",
                        selection: Binding(
                            get: { model.appearance.lightTheme },
                            set: { model.appearance.lightTheme = $0 }
                        )
                    )
                    ReaderAutomaticThemeRow(
                        title: "Dark mode",
                        selection: Binding(
                            get: { model.appearance.darkTheme },
                            set: { model.appearance.darkTheme = $0 }
                        )
                    )
                }
                Text("The reader changes with the app and system appearance.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            } else {
                HStack(spacing: 10) {
                    ForEach(ReaderThemeOption.allCases) { option in
                        ReaderThemeCard(option: option, isSelected: model.appearance.theme == option) {
                            PlatformHaptics.selection()
                            model.appearance.theme = option
                        }
                    }
                }
            }
        }

        if !model.isFixedLayoutBook {
            VStack(alignment: .leading, spacing: 4) {
                ReaderStepperRow(
                    title: "Text size",
                    display: "\(Int((model.appearance.fontSize * 100).rounded()))%",
                    decreaseLabel: "Smaller text",
                    increaseLabel: "Larger text",
                    onDecrease: { adjustFontSize(-0.1) },
                    onIncrease: { adjustFontSize(0.1) }
                )
                ReaderStepperRow(
                    title: "Line height",
                    display: String(format: "%.2f", model.appearance.lineHeight),
                    decreaseLabel: "Tighter line spacing",
                    increaseLabel: "Looser line spacing",
                    onDecrease: { adjustLineHeight(-0.05) },
                    onIncrease: { adjustLineHeight(0.05) }
                )
                ReaderStepperRow(
                    title: "Margins",
                    display: String(format: "%.1f", model.appearance.pageMargins),
                    decreaseLabel: "Narrower margins",
                    increaseLabel: "Wider margins",
                    onDecrease: { adjustMargins(-0.1) },
                    onIncrease: { adjustMargins(0.1) }
                )
                ReaderStepperRow(
                    title: "Top & bottom",
                    display: String(format: "%.1f", model.appearance.topMargins),
                    decreaseLabel: "Smaller top and bottom margins",
                    increaseLabel: "Larger top and bottom margins",
                    onDecrease: { adjustVerticalMargins(-0.1) },
                    onIncrease: { adjustVerticalMargins(0.1) }
                )
                ReaderStepperRow(
                    title: "Paragraph spacing",
                    display: String(format: "%.2f", model.appearance.paragraphSpacing),
                    decreaseLabel: "Less paragraph spacing",
                    increaseLabel: "More paragraph spacing",
                    onDecrease: { adjust(\.paragraphSpacing, by: -0.25, min: 0, max: 2) },
                    onIncrease: { adjust(\.paragraphSpacing, by: 0.25, min: 0, max: 2) }
                )
                ReaderStepperRow(
                    title: "Paragraph indent",
                    display: String(format: "%.2f", model.appearance.paragraphIndent),
                    decreaseLabel: "Less paragraph indentation",
                    increaseLabel: "More paragraph indentation",
                    onDecrease: { adjust(\.paragraphIndent, by: -0.25, min: 0, max: 3) },
                    onIncrease: { adjust(\.paragraphIndent, by: 0.25, min: 0, max: 3) }
                )
                ReaderStepperRow(
                    title: "Word spacing",
                    display: String(format: "%.2f", model.appearance.wordSpacing),
                    decreaseLabel: "Less word spacing",
                    increaseLabel: "More word spacing",
                    onDecrease: { adjust(\.wordSpacing, by: -0.1, min: 0, max: 1) },
                    onIncrease: { adjust(\.wordSpacing, by: 0.1, min: 0, max: 1) }
                )
                ReaderStepperRow(
                    title: "Letter spacing",
                    display: String(format: "%.2f", model.appearance.letterSpacing),
                    decreaseLabel: "Less letter spacing",
                    increaseLabel: "More letter spacing",
                    onDecrease: { adjust(\.letterSpacing, by: -0.05, min: 0, max: 0.5) },
                    onIncrease: { adjust(\.letterSpacing, by: 0.05, min: 0, max: 0.5) }
                )
            }

            brightnessControl

            flowControls

            typesettingToggles

            gestureToggles

            bionicToggle

            fontPicker

            fontLibrarySection
        }
    }

    private var bionicToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                isOn: Binding(
                    get: { model.appearance.bionicReading },
                    set: { model.appearance.bionicReading = $0 }
                )
            ) {
                Text("Bionic reading")
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.text)
            }
            .tint(hearth.ember)
            Text("Bolds the first letters of each word to anchor the eye.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
        }
        .padding(.vertical, 2)
    }

    private var brightnessControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Overline("Reader dimmer")
            HStack(spacing: 12) {
                Image(systemName: "sun.min").font(.hearthUI(13)).foregroundStyle(hearth.textSecondary)
                Slider(
                    value: Binding(
                        get: { model.appearance.brightness },
                        set: { model.appearance.brightness = $0 }
                    ),
                    in: 0.2...1.0
                )
                .tint(hearth.ember)
                Image(systemName: "sun.max.fill").font(.hearthUI(13)).foregroundStyle(hearth.textSecondary)
            }
        }
    }

    private var typesettingToggles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Overline("Typesetting")
            readerToggle(
                "Justified text",
                isOn: Binding(
                    get: { model.appearance.justifiedText },
                    set: { model.appearance.justifiedText = $0 }
                )
            )
            readerToggle(
                "Respect publisher styling",
                isOn: Binding(
                    get: { model.appearance.publisherStyles },
                    set: { model.appearance.publisherStyles = $0 }
                )
            )
        }
    }

    private var gestureToggles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Overline("Page turns")
            readerToggle(
                "Tap the edges",
                isOn: Binding(
                    get: { model.appearance.tapEdgesTurnPages },
                    set: { model.appearance.tapEdgesTurnPages = $0 }
                )
            )
            readerToggle(
                "Volume buttons",
                isOn: Binding(
                    get: { model.appearance.volumeButtonsTurnPages },
                    set: { model.appearance.volumeButtonsTurnPages = $0 }
                )
            )
        }
    }

    private var nextSeriesControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Overline("At the end")
            readerToggle(
                "Suggest the next book",
                isOn: Binding(
                    get: { model.appearance.showNextSeriesPrompt },
                    set: { model.appearance.showNextSeriesPrompt = $0 }
                )
            )
            if model.appearance.showNextSeriesPrompt {
                HStack(spacing: 8) {
                    ForEach(ReaderNextSeriesPromptPlacement.allCases) { placement in
                        HearthChip(
                            title: placement.label,
                            isSelected: model.appearance.nextSeriesPromptPlacement == placement
                        ) {
                            PlatformHaptics.selection()
                            model.appearance.nextSeriesPromptPlacement = placement
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Next book suggestion position")
            }
        }
    }

    private func readerToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.hearthUI(15, weight: .medium))
                .foregroundStyle(hearth.text)
        }
        .tint(hearth.ember)
    }

    private var flowControls: some View {
        let isPDF: Bool
        if case .readyPDF = model.state {
            isPDF = true
        } else {
            isPDF = false
        }
        let scrollEnabled = isPDF ? model.appearance.pdfScrollEnabled : model.appearance.scrollEnabled
        return VStack(alignment: .leading, spacing: 12) {
            Overline("Page flow")
            HStack(spacing: 8) {
                HearthChip(title: "Paged", isSelected: !scrollEnabled) {
                    PlatformHaptics.selection()
                    if isPDF {
                        model.appearance.pdfScrollEnabled = false
                    } else {
                        model.appearance.scrollEnabled = false
                    }
                }
                HearthChip(title: "Scrolled", isSelected: scrollEnabled) {
                    PlatformHaptics.selection()
                    if isPDF {
                        model.appearance.pdfScrollEnabled = true
                    } else {
                        model.appearance.scrollEnabled = true
                    }
                }
            }
        }
    }

    private var fontPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Overline("Typeface")
            VStack(spacing: 0) {
                ForEach(ReaderFontFamilyOption.allCases) { option in
                    fontRow(
                        label: option.label,
                        font: builtinPreviewFont(option),
                        isSelected: !model.appearance.usesCustomFont && model.appearance.fontFamily == option
                    ) {
                        model.appearance.usesCustomFont = false
                        model.appearance.customFontFamilyName = nil
                        model.appearance.fontFamily = option
                    }
                }
                ForEach(installedFamilies) { family in
                    fontRow(
                        label: family.displayName,
                        font: .custom(family.familyName, size: 17),
                        isSelected: model.appearance.usesCustomFont
                            && model.appearance.customFontFamilyName == family.familyName
                    ) {
                        model.appearance.usesCustomFont = true
                        model.appearance.customFontFamilyName = family.familyName
                    }
                }
            }
            .background {
                RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                    .fill(hearth.bgElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    }
            }
        }
    }

    private var installedFamilies: [ReaderFontLibrary.InstalledFontFamily] {
        fontLibrary.installedFonts.filter { fontLibrary.hasUsableFontFamily(named: $0.familyName) }
    }

    private var fontLibrarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Overline("Font library")
            VStack(spacing: 0) {
                ForEach(ReaderFontLibrary.GoogleFontFamily.allCases, id: \.id) { family in
                    googleFontRow(family)
                }
                Button {
                    showingFontImporter = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.hearthUI(14, weight: .medium))
                            .foregroundStyle(hearth.ember)
                        Text("Bring in a .ttf or .otf")
                            .font(.hearthUI(15, weight: .medium))
                            .foregroundStyle(hearth.text)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            }
            .background {
                RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                    .fill(hearth.bgElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    }
            }
        }
    }

    private func googleFontRow(_ family: ReaderFontLibrary.GoogleFontFamily) -> some View {
        let installed = fontLibrary.fontFamily(named: family.familyName) != nil
        return Button {
            guard !installed, installingFontId == nil else { return }
            installingFontId = family.id
            Task {
                defer { installingFontId = nil }
                do {
                    let font = try await fontLibrary.installGoogleFont(family)
                    model.appearance.customFontFamilyName = font.familyName
                    model.appearance.usesCustomFont = true
                    PlatformHaptics.impact(.light)
                } catch {
                    fontError = error.localizedDescription
                }
            }
        } label: {
            HStack {
                Text(family.displayName)
                    .font(installed ? .custom(family.familyName, size: 16) : .hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.text)
                Spacer()
                if installed {
                    Text("On hand")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                } else if installingFontId == family.id {
                    ProgressView()
                        .controlSize(.small)
                        .tint(hearth.ember)
                } else {
                    Text("Fetch")
                        .font(.hearthUI(13, weight: .semibold))
                        .foregroundStyle(hearth.ember)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(installed)
    }

    private func fontRow(label: String, font: Font, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            PlatformHaptics.selection()
            action()
        } label: {
            HStack {
                Text(label)
                    .font(font)
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.hearthUI(13, weight: .semibold))
                        .foregroundStyle(hearth.ember)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func builtinPreviewFont(_ option: ReaderFontFamilyOption) -> Font {
        switch option {
        case .serif: .hearthDisplay(17, weight: .regular)
        case .sansSerif: .system(size: 17)
        case .openDyslexic: .system(size: 17, design: .rounded)
        case .duospace: .system(size: 17, design: .monospaced)
        }
    }

    @ViewBuilder
    private var comicControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Overline("Page flow")
            HStack(spacing: 8) {
                comicLayoutChip(.scroll, title: "Scroll")
                comicLayoutChip(.leftToRight, title: "Left to right")
                comicLayoutChip(.rightToLeft, title: "Right to left")
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            Overline("Page fit")
            HStack(spacing: 8) {
                ForEach(ComicPageFit.allCases) { fit in
                    HearthChip(title: fit.label, isSelected: model.appearance.comicPageFit == fit) {
                        PlatformHaptics.selection()
                        model.appearance.comicPageFit = fit
                    }
                }
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            Overline("Zoom")
            VStack(spacing: 0) {
                comicToggleRow(
                    title: "Tap-to-zoom",
                    note: "Let a double tap move closer to the art.",
                    isOn: Binding(
                        get: { model.appearance.comicZoomEnabled },
                        set: { value in
                            PlatformHaptics.selection()
                            model.appearance.comicZoomEnabled = value
                        }
                    )
                )
                comicDivider
                comicToggleRow(
                    title: "One-handed zoom",
                    note: "A thumb-friendly zoom path for page turns.",
                    isOn: Binding(
                        get: { model.appearance.comicOneHandedZoom },
                        set: { value in
                            PlatformHaptics.selection()
                            model.appearance.comicOneHandedZoom = value
                        }
                    )
                )
                .disabled(!model.appearance.comicZoomEnabled)
                .opacity(model.appearance.comicZoomEnabled ? 1 : 0.48)
            }
            .background {
                RoundedRectangle(cornerRadius: Hearth.radiusInner, style: .continuous)
                    .fill(hearth.bgElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: Hearth.radiusInner, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    }
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            Overline("Landscape")
            comicToggleRow(
                title: "Two-page spread",
                note: "Open paired pages when the device turns sideways.",
                isOn: Binding(
                    get: { model.appearance.comicLandscapeSpread },
                    set: { value in
                        PlatformHaptics.selection()
                        model.appearance.comicLandscapeSpread = value
                    }
                )
            )
            .background {
                RoundedRectangle(cornerRadius: Hearth.radiusInner, style: .continuous)
                    .fill(hearth.bgElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: Hearth.radiusInner, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    }
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            Overline("Background")
            HStack(spacing: 8) {
                ForEach(ComicBackgroundColor.allCases) { color in
                    HearthChip(title: color.label, isSelected: model.appearance.comicBackgroundColor == color) {
                        PlatformHaptics.selection()
                        model.appearance.comicBackgroundColor = color
                    }
                }
            }
        }
    }

    private func comicLayoutChip(_ layout: ReaderComicLayoutOption, title: String) -> some View {
        HearthChip(title: title, isSelected: model.appearance.comicLayout == layout) {
            PlatformHaptics.selection()
            model.appearance.comicLayout = layout
        }
    }

    private func comicToggleRow(title: String, note: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.text)
                Text(note)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(hearth.ember)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var comicDivider: some View {
        Rectangle()
            .fill(hearth.hairline)
            .frame(height: 1)
            .padding(.leading, 16)
    }

    private func adjustFontSize(_ delta: Double) {
        model.appearance.fontSize = min(3.0, max(0.5, model.appearance.fontSize + delta))
        PlatformHaptics.selection()
    }

    private func adjustLineHeight(_ delta: Double) {
        model.appearance.lineHeight = min(2.0, max(1.1, model.appearance.lineHeight + delta))
        PlatformHaptics.selection()
    }

    private func adjustMargins(_ delta: Double) {
        model.appearance.pageMargins = min(2.0, max(0.0, model.appearance.pageMargins + delta))
        PlatformHaptics.selection()
    }

    private func adjustVerticalMargins(_ delta: Double) {
        let value = min(2.0, max(0.0, model.appearance.topMargins + delta))
        model.appearance.topMargins = value
        model.appearance.bottomMargins = value
        PlatformHaptics.selection()
    }

    private func adjust(_ keyPath: WritableKeyPath<ClassicReaderAppearance, Double>, by delta: Double, min lo: Double, max hi: Double) {
        let next = Swift.min(hi, Swift.max(lo, model.appearance[keyPath: keyPath] + delta))
        model.appearance[keyPath: keyPath] = next
        PlatformHaptics.selection()
    }
}

private struct ReaderAutomaticThemeRow: View {
    let title: String
    @Binding var selection: ReaderThemeOption

    @Environment(\.hearth) private var hearth

    var body: some View {
        Menu {
            ForEach(ReaderThemeOption.allCases) { option in
                Button {
                    PlatformHaptics.selection()
                    selection = option
                } label: {
                    if selection == option {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.text)
                Spacer()
                Text(selection.label)
                    .font(.hearthUI(14, weight: .medium))
                    .foregroundStyle(hearth.textSecondary)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selection.previewGradient)
                    .frame(width: 30, height: 24)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.hearthUI(11, weight: .semibold))
                    .foregroundStyle(hearth.textTertiary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(hearth.bgElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .accessibilityLabel("\(title) reader theme")
        .accessibilityValue(selection.label)
    }
}

private struct ReaderThemeCard: View {
    let option: ReaderThemeOption
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(option.previewGradient)
                    .frame(height: 58)
                    .overlay {
                        Text("Aa")
                            .font(.hearthDisplay(19, weight: .semibold))
                            .foregroundStyle(sampleTextColor)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isSelected ? hearth.ember : hearth.hairline, lineWidth: isSelected ? 2 : 1)
                    }
                Text(displayName)
                    .font(.hearthUI(12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? hearth.text : hearth.textSecondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressableStyle())
    }

    private var displayName: String {
        switch option {
        case .paper: "Paper"
        case .sepia: "Sepia"
        case .midnight: "Ink"
        case .eink: "E-ink"
        }
    }

    private var sampleTextColor: Color {
        var sample = ClassicReaderAppearance()
        sample.theme = option
        return sample.primaryTextColor
    }
}

private struct ReaderStepperRow: View {
    let title: String
    let display: String
    let decreaseLabel: String
    let increaseLabel: String
    let onDecrease: () -> Void
    let onIncrease: () -> Void

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.hearthUI(15, weight: .medium))
                .foregroundStyle(hearth.text)
            Spacer()
            Text(display)
                .font(.hearthUI(14, weight: .medium).monospacedDigit())
                .foregroundStyle(hearth.textSecondary)
            GlyphButton(systemImage: "minus", size: 36, glyphSize: 13, label: decreaseLabel, action: onDecrease)
            GlyphButton(systemImage: "plus", size: 36, glyphSize: 13, label: increaseLabel, action: onIncrease)
        }
        .padding(.vertical, 6)
    }
}
