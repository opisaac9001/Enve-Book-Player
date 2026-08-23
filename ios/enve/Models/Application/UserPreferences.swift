import Foundation
import SwiftUI

public struct UserPreferences: Codable, Equatable {
    public var playbackSpeed: Double = 1.0
    public var podcastPlaybackSpeed: Double = 1.0
    public var skipForwardAmount: TimeInterval = 15
    public var skipBackwardAmount: TimeInterval = 15
    public var smartRewindEnabled: Bool = true
    public var smartRewindShortPauseThreshold: TimeInterval = 30
    public var smartRewindLongPauseThreshold: TimeInterval = 300
    public var smartRewindShortAmount: TimeInterval = 5
    public var smartRewindLongAmount: TimeInterval = 15
    public var volume: Double = 1.0

    public var voiceBoostEnabled: Bool = false
    public var voiceBoostPreset: VoiceBoostPreset = .neutral

    public var basicVoiceMode: BasicVoiceMode = .enhanced
    var volumeLevelingStrength: VolumeLevelingStrength = .off

    var showPlayerAutomatically: Bool = false
    var continuousPlaybackEnabled: Bool = true
    var autoPlayNextInSeries: Bool = false
    var useBlurredPlayerBackground: Bool = false
    var showLockScreenProgressBar: Bool = true
    var disableAutoLockWhilePlaying: Bool = false

    var sleepTimerFadeOutEnabled: Bool = true
    var autoSleepEnabled: Bool = false
    var autoSleepStartMinutes: Int = 22 * 60
    var autoSleepEndMinutes: Int = 6 * 60
    var autoSleepTimerMinutes: Int = 30
    var sleepTimerFadeOutDuration: TimeInterval = 30
    var sleepTimerShakeToSnoozeEnabled: Bool = true
    var sleepTimerSnoozeDuration: Int = 10
    var sleepTimerAlwaysOnEnabled: Bool = false
    var sleepTimerLastDurationMinutes: Int = 15
    var sleepTimerPauseDebounceSeconds: TimeInterval = 2.0
    var sleepTimerGentleWakeEnabled: Bool = false
    var sleepTimerRestartScope: SleepTimerRestartScope = .none

    enum SleepTimerRestartScope: String, Codable {
        case none
        case chapter
        case book
        case onlyAfterTimerEnd
        case alwaysOnPlaybackResume
    }

    var eqEnabled: Bool = false
    var eqBands: [Float] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    var independentPitchSemitones: Double = 0.0
    var monoMixEnabled: Bool = false
    var stereoBalance: Float = 0.0
    var noiseReductionLevel: Float = 0.0
    var binauralEnabled: Bool = false

    var theme: AppTheme = .system
    var playerBackgroundStyle: PlayerBackgroundStyle = .albumArt
    public var shellNavigationStyle: ShellNavigationStyle = .classic
    public var preferredStartTab: PreferredStartTab = .hearth
    public var homeSectionOrder: [HomeSection] = HomeSection.allCases
    var primaryColorRed: CGFloat = ThemeManager.defaultAccentRed
    var primaryColorGreen: CGFloat = ThemeManager.defaultAccentGreen
    var primaryColorBlue: CGFloat = ThemeManager.defaultAccentBlue
    var showChapters: Bool = true
    var showBookmarks: Bool = true
    var visionImpairedModeEnabled: Bool = false
    var dynamicBackgroundEnabled: Bool = true

    var autoSyncProgress: Bool = true
    var syncInterval: TimeInterval = 30
    var deviceIdentifier: String = ""

    var defaultLibraryId: String?
    var defaultBackendId: String?
    var sortBy: SortOption = .title
    var sortOrder: SortOrder = .ascending
    var authorNameSort: AuthorNameSort = .givenName
    var sortLevels: [SortLevel] = []
    var authorSortOption: AuthorSortOption = .firstName
    var excludedLibraryIds: Set<String> = []
    var hiddenBookIds: Set<String> = []
    var hiddenBookNames: [String: String] = [:]

    public var titleDisplayMode: TitleDisplayMode = .stripPrefix
    public var subtitleHandling: SubtitleHandling = .keep
    public var mergeAggressiveness: MergeAggressiveness = .normal
    public var authorGroupingThreshold: Double = 0.85
    public var showAdvancedLibrarySettings: Bool = false

    public var dedupExcludedProviderIds: Set<String> = []
    public var dedupExcludedLibraryIds: Set<String> = []
    public var dedupFetchMissingDuration: Bool = true

    public var autoMatchThreshold: Double = 0.85
    public var autoMatchDurationTolerance: TimeInterval = 120.0

    public var autoClearCacheEnabled: Bool = true
    public var expireOldMetadataEnabled: Bool = false
    public var compressCoversEnabled: Bool = true

    public var autoDeleteFinishedBooks: Bool = false
    public var autoDeleteFailedDownloads: Bool = true
    public var keepNextItemsOfflineEnabled: Bool = false
    public var keepNextItemsOfflineCount: Int = 1
    var podcastAutoQueueSettings: [String: PodcastAutoQueueSetting] = [:]
    public var storageLimitEnabled: Bool = false
    public var storageLimitGB: Int = 10
    public var preferBookCoverAspectRatio: Bool = false

    public var obsidianSyncEnabled: Bool = false
    public var obsidianAutoExportEnabled: Bool = false
    public var obsidianVaultBookmarkData: Data? = nil
    public var obsidianSubfolder: String = "Enve"
    public var obsidianUpdatePolicy: ObsidianUpdatePolicy = .magic
    public var obsidianAtomicHighlights: Bool = false
    public var obsidianTemplateBody: String = ObsidianDefaults.templateBody
    public var obsidianFilenameTemplate: String = ObsidianDefaults.filenameTemplate
    public var obsidianLastSyncDates: [String: Date] = [:]

    public var vocabAutoLogLookups: Bool = true

    public var studyDailyNewLimit: Int = 10
    public var studyShowSentenceFirst: Bool = false
    public var studyShuffleQueue: Bool = true

    public enum ObsidianUpdatePolicy: String, Codable, CaseIterable, Identifiable, Sendable {
        case replace
        case append
        case smartInsert
        case magic

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .replace: return "Replace"
            case .append: return "Append"
            case .smartInsert: return "Smart Insert"
            case .magic: return "Magic"
            }
        }

        public var description: String {
            switch self {
            case .replace: return "Always overwrite the file. User edits in the file are lost."
            case .append: return "Add only new highlights to the end. Don't modify existing ones."
            case .smartInsert: return "Add new highlights only. Never modify or remove anything that already exists."
            case .magic: return "Insert highlights in book order, update edited ones, preserve any text you've added between markers."
            }
        }
    }

    public enum ObsidianDefaults {
        nonisolated public static let filenameTemplate = "{{ book.title | sanitize_filename }}.md"
        nonisolated public static let templateBody = """
            ---
            title: "{{ book.title | escape_md }}"
            authors: [{% for a in book.authors %}"{{ a | escape_md }}"{% if forloop.last == false %}, {% endif %}{% endfor %}]
            {% if book.series %}series: "{{ book.series | escape_md }}"
            series_number: "{{ book.seriesNumber | default: "" }}"
            {% endif %}{% if book.publishedYear %}year: {{ book.publishedYear }}
            {% endif %}{% if book.isbn %}isbn: "{{ book.isbn }}"
            {% endif %}{% if book.asin %}asin: "{{ book.asin }}"
            {% endif %}tags: [enve, {{ book.mediaType }}{% for g in book.genres %}, "{{ g }}"{% endfor %}]
            progress: {{ book.progress }}
            last_synced: "{{ exportedAt | date: "yyyy-MM-dd HH:mm" }}"
            enve_book_id: "{{ book.id }}"
            ---

            # {{ book.title }}
            {% if book.authors %}*by {{ book.authors | join: ", " }}*{% endif %}

            {% if highlights %}## Highlights

            {% for h in highlights %}<!-- enve-meta:{"id":"{{ h.id }}","color":"{{ h.colorHex }}","pos":{{ h.position }}} -->
            <!-- enve-highlight:{{ h.id }} start -->
            {% if h.chapterTitle %}**{{ h.chapterTitle }}**

            {% endif %}> {{ h.text | escape_md }}
            {% if h.note %}

            **Note:** {{ h.note | escape_md }}{% endif %}
            <!-- enve-highlight:{{ h.id }} end -->

            {% endfor %}{% endif %}{% if audiobookNotes %}## Audiobook Notes

            {% for n in audiobookNotes %}<!-- enve-highlight:{{ n.id }} start -->
            - **{{ n.formattedTime }}** - {{ n.title | escape_md }}{% if n.note %}
              > {{ n.note | escape_md }}{% endif %}
            <!-- enve-highlight:{{ n.id }} end -->

            {% endfor %}{% endif %}{% if ebookBookmarks %}## Bookmarks

            {% for b in ebookBookmarks %}- {{ b.chapterTitle | default: b.title }}{% if b.note %} - {{ b.note | escape_md }}{% endif %}
            {% endfor %}{% endif %}
            """
    }

    public enum AppTheme: String, Codable {
        case light
        case dark
        case oled
        case system
    }

    public enum PlayerBackgroundStyle: String, Codable {
        case albumArt
        case solid
    }

    public enum ShellNavigationStyle: String, Codable, CaseIterable, Identifiable {
        case classic
        case liquidGlass

        public var id: String { rawValue }

        var displayName: String {
            switch self {
            case .classic: return "Classic"
            case .liquidGlass: return "Liquid Glass"
            }
        }

        var description: String {
            switch self {
            case .classic: return "Anchored Hearth bar with a solid background."
            case .liquidGlass: return "Floating nav that lets content breathe underneath."
            }
        }
    }

    public enum PreferredStartTab: String, Codable, CaseIterable, Identifiable {
        case hearth
        case library
        case podcasts
        case journal

        public var id: String { rawValue }

        var displayName: String {
            switch self {
            case .hearth: "Hearth"
            case .library: "Library"
            case .podcasts: "Podcasts"
            case .journal: "Journal"
            }
        }
    }

    public enum HomeSection: String, Codable, CaseIterable, Identifiable {
        case continueReading
        case continueListening
        case recentlyAdded
        case downloaded
        case doorways

        public var id: String { rawValue }

        var displayName: String {
            switch self {
            case .continueReading: "Continue Reading"
            case .continueListening: "Continue Listening"
            case .recentlyAdded: "Recently Added"
            case .downloaded: "On this device"
            case .doorways: "Doorways"
            }
        }

        var glyph: String {
            switch self {
            case .continueReading: "book.pages"
            case .continueListening: "headphones"
            case .recentlyAdded: "sparkles"
            case .downloaded: "arrow.down.circle"
            case .doorways: "rectangle.portrait.and.arrow.right"
            }
        }
    }

    var normalizedHomeSectionOrder: [HomeSection] {
        var seen = Set<HomeSection>()
        return (homeSectionOrder + HomeSection.allCases).filter { seen.insert($0).inserted }
    }

    public enum SortOption: String, Codable, CaseIterable, Identifiable {
        case title
        case author
        case narrator
        case dateAdded
        case progress
        case duration
        case publishedYear
        case seriesOrder
        case authorSeriesList

        public var id: String { rawValue }

        var displayName: String {
            switch self {
            case .title: return "Title"
            case .author: return "Author"
            case .narrator: return "Narrator"
            case .dateAdded: return "Recently Added"
            case .progress: return "Progress"
            case .duration: return "Duration"
            case .publishedYear: return "Published Year"
            case .seriesOrder: return "Series Order"
            case .authorSeriesList: return "Author & Series"
            }
        }

        var iconName: String {
            switch self {
            case .title: return "textformat"
            case .author: return "person"
            case .narrator: return "person.wave.2"
            case .dateAdded: return "calendar"
            case .progress: return "chart.bar.fill"
            case .duration: return "clock"
            case .publishedYear: return "calendar.badge.clock"
            case .seriesOrder: return "list.number"
            case .authorSeriesList: return "person.text.rectangle"
            }
        }
    }

    public enum SortOrder: String, Codable, CaseIterable, Identifiable {
        case ascending
        case descending

        public var id: String { rawValue }

        var iconName: String {
            switch self {
            case .ascending: return "arrow.up"
            case .descending: return "arrow.down"
            }
        }
    }

    public struct SortLevel: Codable, Identifiable, Equatable, Sendable {
        public var id: String { field.rawValue }
        public var field: SortOption
        public var order: SortOrder

        public var authorNameSort: AuthorNameSort

        public init(field: SortOption, order: SortOrder = .ascending, authorNameSort: AuthorNameSort = .givenName) {
            self.field = field
            self.order = order
            self.authorNameSort = authorNameSort
        }
    }

    var migratedSortLevels: [SortLevel] {
        if !sortLevels.isEmpty { return sortLevels }
        return [SortLevel(field: sortBy, order: sortOrder, authorNameSort: authorNameSort)]
    }

    public enum AuthorNameSort: String, Codable, CaseIterable, Identifiable {
        case givenName
        case surname

        public var id: String { rawValue }

        var displayName: String {
            switch self {
            case .givenName: return "Given Name"
            case .surname: return "Surname"
            }
        }
    }

    public enum AuthorSortOption: String, Codable, CaseIterable, Identifiable {
        case firstName
        case surname
        case bookCount

        public var id: String { rawValue }

        var displayName: String {
            switch self {
            case .firstName: return "First Name"
            case .surname: return "Last Name"
            case .bookCount: return "Book Count"
            }
        }

        var iconName: String {
            switch self {
            case .firstName: return "a.circle"
            case .surname: return "person.text.rectangle"
            case .bookCount: return "number.circle"
            }
        }
    }

    public enum SeriesSortOption: String, Codable, CaseIterable, Identifiable {
        case name
        case bookCount

        public var id: String { rawValue }

        var displayName: String {
            switch self {
            case .name: return "Name"
            case .bookCount: return "Book Count"
            }
        }

        var iconName: String {
            switch self {
            case .name: return "a.circle"
            case .bookCount: return "number.circle"
            }
        }
    }

    public enum TitleDisplayMode: String, Codable, CaseIterable, Identifiable {
        case preserve
        case stripPrefix
        case moveToSuffix
        case extractToSeries

        public var id: String { rawValue }

        var displayName: String {
            switch self {
            case .preserve: return "Preserve"
            case .stripPrefix: return "Strip Prefix"
            case .moveToSuffix: return "Move to Suffix"
            case .extractToSeries: return "Extract to Series"
            }
        }

        var description: String {
            switch self {
            case .preserve: return "Show the original title as-is"
            case .stripPrefix: return "Remove leading series/book numbers"
            case .moveToSuffix: return "Move leading numbers to the end"
            case .extractToSeries: return "Strip leading numbers (series handled separately)"
            }
        }

        var iconName: String {
            switch self {
            case .preserve: return "text.justify"
            case .stripPrefix: return "scissors"
            case .moveToSuffix: return "text.append"
            case .extractToSeries: return "number"
            }
        }
    }

    public enum SubtitleHandling: String, Codable, CaseIterable, Identifiable {
        case keep
        case remove

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .keep: return "Keep Subtitles"
            case .remove: return "Remove Subtitles"
            }
        }

        var description: String {
            switch self {
            case .keep: return "Show subtitle text after a colon"
            case .remove: return "Hide text after a colon"
            }
        }
    }

    public enum MergeAggressiveness: String, Codable, CaseIterable, Identifiable {
        case conservative
        case normal
        case aggressive

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .conservative: return "Conservative"
            case .normal: return "Normal"
            case .aggressive: return "Aggressive"
            }
        }

        public var iconName: String {
            switch self {
            case .conservative: return "shield.checkered"
            case .normal: return "slider.horizontal.3"
            case .aggressive: return "bolt.fill"
            }
        }

        public var candidateThreshold: Int {
            switch self {
            case .conservative: return 95
            case .normal: return 85
            case .aggressive: return 75
            }
        }

        public var description: String {
            switch self {
            case .conservative: return "Only merge clearly identical duplicates"
            case .normal: return "Balanced duplicate detection"
            case .aggressive: return "Merge aggressively (risk of false positives)"
            }
        }
    }

    nonisolated public static let `default` = UserPreferences()

    nonisolated public init() {}

    private enum CodingKeys: String, CodingKey {
        case playbackSpeed, podcastPlaybackSpeed
        case skipForwardAmount, skipBackwardAmount
        case smartRewindEnabled, smartRewindShortPauseThreshold, smartRewindLongPauseThreshold
        case smartRewindShortAmount, smartRewindLongAmount
        case volume
        case voiceBoostEnabled, voiceBoostPreset, basicVoiceMode, volumeLevelingStrength
        case showPlayerAutomatically, continuousPlaybackEnabled, autoPlayNextInSeries, useBlurredPlayerBackground
        case showLockScreenProgressBar, disableAutoLockWhilePlaying
        case sleepTimerFadeOutEnabled, sleepTimerFadeOutDuration
        case autoSleepEnabled, autoSleepStartMinutes, autoSleepEndMinutes, autoSleepTimerMinutes
        case sleepTimerShakeToSnoozeEnabled, sleepTimerSnoozeDuration
        case sleepTimerAlwaysOnEnabled, sleepTimerLastDurationMinutes
        case sleepTimerPauseDebounceSeconds, sleepTimerGentleWakeEnabled
        case sleepTimerRestartScope
        case eqEnabled, eqBands, independentPitchSemitones
        case monoMixEnabled, stereoBalance, noiseReductionLevel, binauralEnabled
        case theme, playerBackgroundStyle, shellNavigationStyle, preferredStartTab, homeSectionOrder
        case primaryColorRed, primaryColorGreen, primaryColorBlue
        case showChapters, showBookmarks, visionImpairedModeEnabled, dynamicBackgroundEnabled
        case autoSyncProgress, syncInterval, deviceIdentifier
        case defaultLibraryId, defaultBackendId
        case sortBy, sortOrder, authorNameSort, sortLevels, authorSortOption
        case excludedLibraryIds, hiddenBookIds, hiddenBookNames
        case titleDisplayMode, subtitleHandling, mergeAggressiveness
        case authorGroupingThreshold, showAdvancedLibrarySettings
        case dedupExcludedProviderIds, dedupExcludedLibraryIds, dedupFetchMissingDuration
        case autoMatchThreshold, autoMatchDurationTolerance
        case autoClearCacheEnabled, expireOldMetadataEnabled, compressCoversEnabled
        case autoDeleteFinishedBooks, autoDeleteFailedDownloads
        case keepNextItemsOfflineEnabled, keepNextItemsOfflineCount
        case podcastAutoQueueSettings
        case storageLimitEnabled, storageLimitGB, preferBookCoverAspectRatio
        case obsidianSyncEnabled, obsidianAutoExportEnabled, obsidianVaultBookmarkData
        case obsidianSubfolder, obsidianUpdatePolicy, obsidianAtomicHighlights
        case obsidianTemplateBody, obsidianFilenameTemplate, obsidianLastSyncDates
        case vocabAutoLogLookups
        case studyDailyNewLimit, studyShowSentenceFirst, studyShuffleQueue
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)

        func decode<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(type, forKey: key))
        }

        if let v = decode(Double.self, .playbackSpeed) { playbackSpeed = v }
        if let v = decode(Double.self, .podcastPlaybackSpeed) { podcastPlaybackSpeed = v }
        if let v = decode(TimeInterval.self, .skipForwardAmount) { skipForwardAmount = v }
        if let v = decode(TimeInterval.self, .skipBackwardAmount) { skipBackwardAmount = v }
        if let v = decode(Bool.self, .smartRewindEnabled) { smartRewindEnabled = v }
        if let v = decode(TimeInterval.self, .smartRewindShortPauseThreshold) { smartRewindShortPauseThreshold = v }
        if let v = decode(TimeInterval.self, .smartRewindLongPauseThreshold) { smartRewindLongPauseThreshold = v }
        if let v = decode(TimeInterval.self, .smartRewindShortAmount) { smartRewindShortAmount = v }
        if let v = decode(TimeInterval.self, .smartRewindLongAmount) { smartRewindLongAmount = v }
        if let v = decode(Double.self, .volume) { volume = v }

        if let v = decode(Bool.self, .voiceBoostEnabled) { voiceBoostEnabled = v }
        if let v = decode(VoiceBoostPreset.self, .voiceBoostPreset) { voiceBoostPreset = v }
        if let v = decode(BasicVoiceMode.self, .basicVoiceMode) { basicVoiceMode = v }
        if let v = decode(VolumeLevelingStrength.self, .volumeLevelingStrength) { volumeLevelingStrength = v }

        if let v = decode(Bool.self, .showPlayerAutomatically) { showPlayerAutomatically = v }
        if let v = decode(Bool.self, .continuousPlaybackEnabled) { continuousPlaybackEnabled = v }
        if let v = decode(Bool.self, .autoPlayNextInSeries) { autoPlayNextInSeries = v }
        if let v = decode(Bool.self, .useBlurredPlayerBackground) { useBlurredPlayerBackground = v }
        if let v = decode(Bool.self, .showLockScreenProgressBar) { showLockScreenProgressBar = v }
        if let v = decode(Bool.self, .disableAutoLockWhilePlaying) { disableAutoLockWhilePlaying = v }

        if let v = decode(Bool.self, .sleepTimerFadeOutEnabled) { sleepTimerFadeOutEnabled = v }
        if let v = decode(Bool.self, .autoSleepEnabled) { autoSleepEnabled = v }
        if let v = decode(Int.self, .autoSleepStartMinutes) { autoSleepStartMinutes = v }
        if let v = decode(Int.self, .autoSleepEndMinutes) { autoSleepEndMinutes = v }
        if let v = decode(Int.self, .autoSleepTimerMinutes) { autoSleepTimerMinutes = v }
        if let v = decode(TimeInterval.self, .sleepTimerFadeOutDuration) { sleepTimerFadeOutDuration = v }
        if let v = decode(Bool.self, .sleepTimerShakeToSnoozeEnabled) { sleepTimerShakeToSnoozeEnabled = v }
        if let v = decode(Int.self, .sleepTimerSnoozeDuration) { sleepTimerSnoozeDuration = v }
        if let v = decode(Bool.self, .sleepTimerAlwaysOnEnabled) { sleepTimerAlwaysOnEnabled = v }
        if let v = decode(Int.self, .sleepTimerLastDurationMinutes) { sleepTimerLastDurationMinutes = v }
        if let v = decode(TimeInterval.self, .sleepTimerPauseDebounceSeconds) { sleepTimerPauseDebounceSeconds = v }
        if let v = decode(Bool.self, .sleepTimerGentleWakeEnabled) { sleepTimerGentleWakeEnabled = v }
        if let v = decode(SleepTimerRestartScope.self, .sleepTimerRestartScope) { sleepTimerRestartScope = v }

        if let v = decode(Bool.self, .eqEnabled) { eqEnabled = v }
        if let v = decode([Float].self, .eqBands) { eqBands = v }
        if let v = decode(Double.self, .independentPitchSemitones) { independentPitchSemitones = v }
        if let v = decode(Bool.self, .monoMixEnabled) { monoMixEnabled = v }
        if let v = decode(Float.self, .stereoBalance) { stereoBalance = v }
        if let v = decode(Float.self, .noiseReductionLevel) { noiseReductionLevel = v }
        if let v = decode(Bool.self, .binauralEnabled) { binauralEnabled = v }

        if let v = decode(AppTheme.self, .theme) { theme = v }
        if let v = decode(PlayerBackgroundStyle.self, .playerBackgroundStyle) { playerBackgroundStyle = v }
        if let v = decode(ShellNavigationStyle.self, .shellNavigationStyle) { shellNavigationStyle = v }
        if let v = decode(PreferredStartTab.self, .preferredStartTab) { preferredStartTab = v }
        if let v = decode([HomeSection].self, .homeSectionOrder) { homeSectionOrder = v }
        if let v = decode(CGFloat.self, .primaryColorRed) { primaryColorRed = v }
        if let v = decode(CGFloat.self, .primaryColorGreen) { primaryColorGreen = v }
        if let v = decode(CGFloat.self, .primaryColorBlue) { primaryColorBlue = v }
        if let v = decode(Bool.self, .showChapters) { showChapters = v }
        if let v = decode(Bool.self, .showBookmarks) { showBookmarks = v }
        if let v = decode(Bool.self, .visionImpairedModeEnabled) { visionImpairedModeEnabled = v }
        if let v = decode(Bool.self, .dynamicBackgroundEnabled) { dynamicBackgroundEnabled = v }

        if let v = decode(Bool.self, .autoSyncProgress) { autoSyncProgress = v }
        if let v = decode(TimeInterval.self, .syncInterval) { syncInterval = v }
        if let v = decode(String.self, .deviceIdentifier) { deviceIdentifier = v }

        if let v = decode(String.self, .defaultLibraryId) { defaultLibraryId = v }
        if let v = decode(String.self, .defaultBackendId) { defaultBackendId = v }

        if let v = decode(SortOption.self, .sortBy) { sortBy = v }
        if let v = decode(SortOrder.self, .sortOrder) { sortOrder = v }
        if let v = decode(AuthorNameSort.self, .authorNameSort) { authorNameSort = v }
        if let v = decode([SortLevel].self, .sortLevels) { sortLevels = v }
        if let v = decode(AuthorSortOption.self, .authorSortOption) { authorSortOption = v }
        if let v = decode(Set<String>.self, .excludedLibraryIds) { excludedLibraryIds = v }
        if let v = decode(Set<String>.self, .hiddenBookIds) { hiddenBookIds = v }
        if let v = decode([String: String].self, .hiddenBookNames) { hiddenBookNames = v }

        if let v = decode(TitleDisplayMode.self, .titleDisplayMode) { titleDisplayMode = v }
        if let v = decode(SubtitleHandling.self, .subtitleHandling) { subtitleHandling = v }
        if let v = decode(MergeAggressiveness.self, .mergeAggressiveness) { mergeAggressiveness = v }
        if let v = decode(Double.self, .authorGroupingThreshold) { authorGroupingThreshold = v }
        if let v = decode(Bool.self, .showAdvancedLibrarySettings) { showAdvancedLibrarySettings = v }

        if let v = decode(Set<String>.self, .dedupExcludedProviderIds) { dedupExcludedProviderIds = v }
        if let v = decode(Set<String>.self, .dedupExcludedLibraryIds) { dedupExcludedLibraryIds = v }
        if let v = decode(Bool.self, .dedupFetchMissingDuration) { dedupFetchMissingDuration = v }

        if let v = decode(Double.self, .autoMatchThreshold) { autoMatchThreshold = v }
        if let v = decode(TimeInterval.self, .autoMatchDurationTolerance) { autoMatchDurationTolerance = v }

        if let v = decode(Bool.self, .autoClearCacheEnabled) { autoClearCacheEnabled = v }
        if let v = decode(Bool.self, .expireOldMetadataEnabled) { expireOldMetadataEnabled = v }
        if let v = decode(Bool.self, .compressCoversEnabled) { compressCoversEnabled = v }

        if let v = decode(Bool.self, .autoDeleteFinishedBooks) { autoDeleteFinishedBooks = v }
        if let v = decode(Bool.self, .autoDeleteFailedDownloads) { autoDeleteFailedDownloads = v }
        if let v = decode(Bool.self, .keepNextItemsOfflineEnabled) { keepNextItemsOfflineEnabled = v }
        if let v = decode(Int.self, .keepNextItemsOfflineCount) { keepNextItemsOfflineCount = v }
        if let v = decode([String: PodcastAutoQueueSetting].self, .podcastAutoQueueSettings) { podcastAutoQueueSettings = v }
        if let v = decode(Bool.self, .storageLimitEnabled) { storageLimitEnabled = v }
        if let v = decode(Int.self, .storageLimitGB) { storageLimitGB = v }
        if let v = decode(Bool.self, .preferBookCoverAspectRatio) { preferBookCoverAspectRatio = v }

        if let v = decode(Bool.self, .obsidianSyncEnabled) { obsidianSyncEnabled = v }
        if let v = decode(Bool.self, .obsidianAutoExportEnabled) { obsidianAutoExportEnabled = v }
        if let v = decode(Data.self, .obsidianVaultBookmarkData) { obsidianVaultBookmarkData = v }
        if let v = decode(String.self, .obsidianSubfolder) { obsidianSubfolder = v }
        if let v = decode(ObsidianUpdatePolicy.self, .obsidianUpdatePolicy) { obsidianUpdatePolicy = v }
        if let v = decode(Bool.self, .obsidianAtomicHighlights) { obsidianAtomicHighlights = v }
        if let v = decode(String.self, .obsidianTemplateBody) { obsidianTemplateBody = v }
        if let v = decode(String.self, .obsidianFilenameTemplate) { obsidianFilenameTemplate = v }
        if let v = decode([String: Date].self, .obsidianLastSyncDates) { obsidianLastSyncDates = v }

        if let v = decode(Bool.self, .vocabAutoLogLookups) { vocabAutoLogLookups = v }
        if let v = decode(Int.self, .studyDailyNewLimit) { studyDailyNewLimit = v }
        if let v = decode(Bool.self, .studyShowSentenceFirst) { studyShowSentenceFirst = v }
        if let v = decode(Bool.self, .studyShuffleQueue) { studyShuffleQueue = v }
    }
}
