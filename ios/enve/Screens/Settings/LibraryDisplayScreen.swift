import SwiftUI

struct LibraryDisplayScreen: View {
    @Environment(\.hearth) private var hearth

    @State private var prefs = LibraryDisplayPreferencesStore.shared.loadPreferences()
    @State private var cardStyle = LibraryDisplayPreferencesStore.shared.loadBookCardStyle()
    @State private var isRededuping = false
    @State private var rededupDone = false

    var body: some View {
        SettingsScaffold(
            overline: "Library & content",
            title: "Library display",
            subtitle: "Card style, title cleanup, subtitles, and grouping."
        ) {
            cardStyleCard
            titleModeCard
            subtitleCard
            previewCard

            SourcesCard {
                SourcesToggleRow(
                    title: "Show advanced settings",
                    isOn: Binding(
                        get: { prefs.showAdvancedLibrarySettings },
                        set: { value in prefs = SettingsPrefs.mutate { $0.showAdvancedLibrarySettings = value } }
                    )
                )
            }

            if prefs.showAdvancedLibrarySettings {
                mergeCard
                groupingCard
            }

            mergeCacheCard
        }
        .alert("Re-deduplication complete", isPresented: $rededupDone) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your library will be merged fresh on its next load.")
        }
    }

    private var cardStyleCard: some View {
        SourcesCard {
            Overline("Card style")
            ForEach(BookCardStyle.allCases) { style in
                SettingsChoiceRow(
                    title: style.displayName,
                    caption: style.description,
                    systemImage: style.iconName,
                    isSelected: cardStyle == style
                ) {
                    cardStyle = style
                    LibraryDisplayPreferencesStore.shared.saveBookCardStyle(style)
                    PlatformHaptics.selection()
                }
            }
        }
    }

    private var titleModeCard: some View {
        SourcesCard {
            Overline("Titles")
            ForEach(UserPreferences.TitleDisplayMode.allCases) { mode in
                SettingsChoiceRow(
                    title: mode.displayName,
                    caption: libraryDisplayExample(for: mode),
                    systemImage: mode.iconName,
                    isSelected: prefs.titleDisplayMode == mode
                ) {
                    prefs = SettingsPrefs.mutate { $0.titleDisplayMode = mode }
                    LibraryDisplayFormatter.clearCache()
                    PlatformHaptics.selection()
                }
            }
        }
    }

    private var subtitleCard: some View {
        SourcesCard {
            Overline("Subtitles")
            ForEach(UserPreferences.SubtitleHandling.allCases) { handling in
                SettingsChoiceRow(
                    title: handling.displayName,
                    caption: handling == .keep
                        ? "\u{201C}The Hobbit: An Unexpected Journey\u{201D}"
                        : "\"The Hobbit: An Unexpected...\" -> \"The Hobbit\"",
                    systemImage: handling == .keep ? "text.quote" : "scissors",
                    isSelected: prefs.subtitleHandling == handling
                ) {
                    prefs = SettingsPrefs.mutate { $0.subtitleHandling = handling }
                    LibraryDisplayFormatter.clearCache()
                    PlatformHaptics.selection()
                }
            }
        }
    }

    private var previewCard: some View {
        SourcesCard {
            Overline("Preview")
            previewRow(original: "01 - The Way of Kings", kind: "Series prefix")
            previewRow(original: "Book 3 - Oathbringer", kind: "Book prefix")
            previewRow(original: "The Hobbit: An Unexpected Journey", kind: "With subtitle")
        }
    }

    private func previewRow(original: String, kind: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Overline(kind)
            HStack(spacing: 8) {
                Text(original)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
                    .strikethrough(original != normalized(original), color: hearth.textTertiary.opacity(0.6))
                Image(systemName: "arrow.right")
                    .font(.hearthUI(10))
                    .foregroundStyle(hearth.textTertiary)
                Text(normalized(original))
                    .font(.hearthCaption.weight(.medium))
                    .foregroundStyle(hearth.ember)
            }
        }
    }

    private func normalized(_ title: String) -> String {
        TitleNormalizer.normalize(title, mode: prefs.titleDisplayMode)
    }

    private var mergeCard: some View {
        SourcesCard {
            Overline("Duplicate detection")
            ForEach(UserPreferences.MergeAggressiveness.allCases) { level in
                SettingsChoiceRow(
                    title: level.displayName,
                    caption: "\(level.description) · threshold \(level.candidateThreshold)%",
                    systemImage: level.iconName,
                    isSelected: prefs.mergeAggressiveness == level
                ) {
                    prefs = SettingsPrefs.mutate { $0.mergeAggressiveness = level }
                    PlatformHaptics.selection()
                }
            }
        }
    }

    private var groupingCard: some View {
        SourcesCard {
            HStack {
                Overline("Author & narrator grouping")
                Spacer()
                Text("\(Int(prefs.authorGroupingThreshold * 100))%")
                    .font(.hearthDisplay(18))
                    .foregroundStyle(hearth.ember)
            }
            Slider(
                value: Binding(
                    get: { prefs.authorGroupingThreshold },
                    set: { value in prefs = SettingsPrefs.mutate { $0.authorGroupingThreshold = value } }
                ),
                in: 0.70...1.0,
                step: 0.05
            )
            .tint(hearth.ember)
            Text("Higher needs closer name matches; lower groups more freely.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
        }
    }

    private var mergeCacheCard: some View {
        SourcesCard {
            Overline("Merge cache")
            if let cache = LocalLibraryStorageStore.shared.loadMergeCache() {
                Text("Last merged \(cache.lastDedupDate.formatted(.relative(presentation: .named))) · \(cache.bookCount) books cached")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            } else {
                Text("Nothing cached yet. The library merges on its first load.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            }
            QuietButton(
                title: isRededuping ? "Working…" : "Clear cache and merge again",
                systemImage: "arrow.triangle.2.circlepath"
            ) {
                guard !isRededuping else { return }
                isRededuping = true
                LocalLibraryStorageStore.shared.clearMergeCache()
                isRededuping = false
                rededupDone = true
                PlatformHaptics.notification(.success)
            }
        }
    }
}

private func libraryDisplayExample(for mode: UserPreferences.TitleDisplayMode) -> String {
    switch mode {
    case .preserve: "\u{201C}01 - The Hobbit\u{201D} stays as it is"
    case .stripPrefix: "\"01 - The Hobbit\" -> \"The Hobbit\""
    case .moveToSuffix: "\"01 - The Hobbit\" -> \"The Hobbit (Book 1)\""
    case .extractToSeries: "\"01 - The Hobbit\" -> series #1"
    }
}
