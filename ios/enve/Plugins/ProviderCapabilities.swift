import Foundation

struct ProviderCapabilities: OptionSet, Sendable, Hashable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    static let fullImport = ProviderCapabilities(rawValue: 1 << 0)

    static let pagedImport = ProviderCapabilities(rawValue: 1 << 1)

    static let streamingImport = ProviderCapabilities(rawValue: 1 << 2)

    static let deltaImport = ProviderCapabilities(rawValue: 1 << 3)

    static let recentBooks = ProviderCapabilities(rawValue: 1 << 4)
    static let series = ProviderCapabilities(rawValue: 1 << 5)
    static let collections = ProviderCapabilities(rawValue: 1 << 6)

    static let audiobookProgressPull = ProviderCapabilities(rawValue: 1 << 7)
    static let audiobookProgressPush = ProviderCapabilities(rawValue: 1 << 8)
    static let ebookProgressPull = ProviderCapabilities(rawValue: 1 << 9)
    static let ebookProgressPush = ProviderCapabilities(rawValue: 1 << 10)

    static let downloads = ProviderCapabilities(rawValue: 1 << 11)

    static let coverAuthHeader = ProviderCapabilities(rawValue: 1 << 12)
    static let coverAuthQuery = ProviderCapabilities(rawValue: 1 << 13)

    static let serverPageStreaming = ProviderCapabilities(rawValue: 1 << 14)

    static let backgroundOperation = ProviderCapabilities(rawValue: 1 << 15)
}
