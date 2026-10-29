enum EbookTTSEngineChoice: String, CaseIterable, Identifiable {
    case apple
    case kokoro

    var id: String { rawValue }

    static var allCases: [EbookTTSEngineChoice] {
        #if targetEnvironment(macCatalyst)
        [.apple]
        #else
        [.apple, .kokoro]
        #endif
    }

    var displayName: String {
        switch self {
        case .apple: "Apple voices"
        case .kokoro: "Kokoro"
        }
    }

    var detail: String {
        switch self {
        case .apple: "Built into your iPhone"
        case .kokoro: "Natural English · private and offline"
        }
    }

    var downloadTitle: String {
        switch self {
        case .apple: ""
        case .kokoro: "Download Kokoro"
        }
    }

    var modelName: String {
        switch self {
        case .apple: ""
        case .kokoro: "Kokoro"
        }
    }

    var downloadDetail: String {
        switch self {
        case .apple: ""
        case .kokoro: "About 130 MB · English · 4 voices"
        }
    }
}

enum TTSModelDownloadState: Equatable {
    case notDownloaded
    case downloading(Double)
    case removing
    case ready
    case failed(String)
}
