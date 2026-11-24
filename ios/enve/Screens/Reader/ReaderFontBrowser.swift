#if os(iOS)
import CoreText
import SwiftUI
import UniformTypeIdentifiers

struct ReaderFontBrowser: View {
    @ObservedObject var model: ClassicReaderModel

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var previewSize: CGFloat = 17
    private let fontLibrary = ReaderFontLibrary.shared
    @State private var query = ""
    @State private var category: ReaderFontCatalog.Category?
    @State private var download: Download?
    @State private var failures: [String: String] = [:]
    @State private var showingFontImporter = false
    @State private var importError: String?

    private struct Download {
        let familyName: String
        var progress: Double
        let task: Task<Void, Never>
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    categoryChips
                    onDeviceSection
                    catalogSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .background(hearth.bg)
            .navigationTitle("Fonts")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search fonts"
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .tint(hearth.ember)
                        .accessibilityIdentifier("reader-font-browser-done")
                }
            }
        }
        .hearthPresentationBackground()
        .onDisappear { download?.task.cancel() }
        .fileImporter(isPresented: $showingFontImporter, allowedContentTypes: [.font]) { result in
            do {
                let installed = try fontLibrary.importFontFile(from: try result.get())
                apply(installed.familyName)
            } catch {
                importError = error.localizedDescription
            }
        }
        .alert(
            "That font wouldn't come in.",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button("All right", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                HearthChip(title: "All", isSelected: category == nil) {
                    PlatformHaptics.selection()
                    category = nil
                }
                ForEach(ReaderFontCatalog.Category.allCases) { option in
                    HearthChip(title: option.label, isSelected: category == option) {
                        PlatformHaptics.selection()
                        category = option
                    }
                }
            }
        }
        .hearthHorizontalEdgeFade()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Font category")
    }

    private var installedFamilies: [ReaderFontLibrary.InstalledFontFamily] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return fontLibrary.installedFonts.filter { family in
            fontLibrary.hasUsableFontFamily(named: family.familyName)
                && (trimmed.isEmpty || family.displayName.localizedStandardContains(trimmed))
                && (category == nil || ReaderFontCatalog.family(named: family.familyName)?.category == category)
        }
    }

    private var onDeviceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Overline("On this device")
            LazyVStack(spacing: 0) {
                ForEach(installedFamilies) { family in
                    installedRow(family)
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
                .accessibilityIdentifier("reader-font-import")
            }
            .background(sectionBackground)
        }
    }

    private func installedRow(_ family: ReaderFontLibrary.InstalledFontFamily) -> some View {
        let selected = isSelected(family.familyName)
        return Button {
            PlatformHaptics.selection()
            apply(family.familyName)
        } label: {
            HStack {
                Text(family.displayName)
                    .font(fontLibrary.previewFont(for: family, size: previewSize) ?? .hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
                Spacer()
                if selected {
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
        .accessibilityLabel(family.displayName)
        .accessibilityValue(selected ? "Selected" : "Downloaded")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var catalogFamilies: [ReaderFontCatalog.Family] {
        ReaderFontCatalog.families(matching: query, in: category)
    }

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Overline("Google Fonts")
            Text("Fonts download only when you choose one, then stay on this device for offline reading.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVStack(spacing: 0) {
                ForEach(catalogFamilies) { family in
                    remoteRow(name: family.name, detail: family.category.label)
                }
            }
            .background(sectionBackground)
            if catalogFamilies.isEmpty {
                Text("No fonts match.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            }
        }
    }

    private func remoteRow(name: String, detail: String) -> some View {
        let installed = fontLibrary.hasUsableFontFamily(named: name)
        let selected = installed && isSelected(name)
        let activeDownload = download?.familyName == name ? download : nil
        let failure = failures[name]

        return HStack(spacing: 12) {
            Button {
                PlatformHaptics.selection()
                if installed {
                    apply(name)
                } else {
                    install(name)
                }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name)
                            .font(.hearthUI(15, weight: .medium))
                            .foregroundStyle(hearth.text)
                            .lineLimit(1)
                        Text(failure.map { "Couldn't download. \($0)" } ?? detail)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.hearthUI(13, weight: .semibold))
                            .foregroundStyle(hearth.ember)
                    } else if installed {
                        Text("On hand")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    } else if activeDownload == nil {
                        Text(failure == nil ? "Download" : "Retry")
                            .font(.hearthUI(13, weight: .semibold))
                            .foregroundStyle(hearth.ember)
                    }
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .disabled(activeDownload != nil || (!installed && download != nil))
            .accessibilityLabel(name)
            .accessibilityValue(status(installed: installed, selected: selected, download: activeDownload, failure: failure))
            .accessibilityHint(installed ? "Uses this font" : "Downloads this font and uses it")
            .accessibilityAddTraits(selected ? .isSelected : [])

            if let activeDownload {
                ProgressView(value: activeDownload.progress)
                    .tint(hearth.ember)
                    .frame(width: 56)
                    .accessibilityHidden(true)
                GlyphButton(systemImage: "xmark", size: 32, glyphSize: 12, label: "Stop downloading \(name)") {
                    activeDownload.task.cancel()
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func status(installed: Bool, selected: Bool, download: Download?, failure: String?) -> String {
        if selected { return "Selected" }
        if installed { return "Downloaded" }
        if let download { return "Downloading, \(Int((download.progress * 100).rounded())) percent" }
        if failure != nil { return "Download failed" }
        return "Not downloaded"
    }

    private var sectionBackground: some View {
        RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
            .fill(hearth.bgElevated)
            .overlay {
                RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                    .strokeBorder(hearth.hairline, lineWidth: 1)
            }
    }

    private func isSelected(_ familyName: String) -> Bool {
        model.appearance.usesCustomFont && model.appearance.customFontFamilyName == familyName
    }

    private func apply(_ familyName: String) {
        model.appearance.customFontFamilyName = familyName
        model.appearance.usesCustomFont = true
    }

    private func install(_ name: String) {
        guard download == nil else { return }
        failures[name] = nil
        let task = Task {
            do {
                let installed = try await fontLibrary.installGoogleFontByName(name) { fraction in
                    download?.progress = fraction
                }
                try Task.checkCancellation()
                download = nil
                apply(installed.familyName)
                PlatformHaptics.impact(.light)
            } catch {
                download = nil
                if !Task.isCancelled && !(error is CancellationError) {
                    failures[name] = error.localizedDescription
                }
            }
        }
        download = Download(familyName: name, progress: 0, task: task)
    }
}

extension ReaderFontLibrary {
    func previewFont(for family: InstalledFontFamily, size: CGFloat) -> Font? {
        previewFontDescriptor(for: family).map { Font(CTFontCreateWithFontDescriptor($0, size, nil)) }
    }
}
#endif
