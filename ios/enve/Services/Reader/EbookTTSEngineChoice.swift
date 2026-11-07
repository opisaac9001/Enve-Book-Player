enum EbookTTSEngineChoice: String, CaseIterable, Identifiable {
    case apple
    case kokoro
    case supertonic3
    case pocket

    var id: String { rawValue }

    static var allCases: [EbookTTSEngineChoice] {
        #if targetEnvironment(macCatalyst)
        [.apple]
        #else
        [.apple, .kokoro, .supertonic3, .pocket]
        #endif
    }

    var displayName: String {
        switch self {
        case .apple: "Apple voices"
        case .kokoro: "Kokoro"
        case .supertonic3: "Supertonic 3"
        case .pocket: "Pocket TTS"
        }
    }

    var detail: String {
        switch self {
        case .apple: "Built into your iPhone"
        case .kokoro: "Natural English · private and offline"
        case .supertonic3: "Multilingual · private and offline"
        case .pocket: "Alba · English · private and offline"
        }
    }

    var downloadTitle: String {
        switch self {
        case .apple: ""
        case .kokoro: "Download Kokoro"
        case .supertonic3: "Download Supertonic 3"
        case .pocket: "Download Pocket TTS"
        }
    }

    var modelName: String {
        switch self {
        case .apple: ""
        case .kokoro: "Kokoro"
        case .supertonic3: "Supertonic 3"
        case .pocket: "Pocket TTS"
        }
    }

    var downloadDetail: String {
        switch self {
        case .apple: ""
        case .kokoro: "About 140 MB · English · 4 voices · Apache 2.0"
        case .supertonic3: "About 172 MB · 31 languages · 10 voices"
        case .pocket: "About 370 MB · English · Alba MacKenna"
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
