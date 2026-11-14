import Foundation

nonisolated enum EbookTTSEngineChoice: String, CaseIterable, Identifiable, Sendable {
    case apple
    case kokoro
    case supertonic3
    case pocket
    case phonon

    var id: String { rawValue }

    static var allCases: [EbookTTSEngineChoice] {
        #if targetEnvironment(macCatalyst)
        [.apple]
        #else
        if #available(iOS 18, *) {
            return [.apple, .kokoro, .supertonic3, .pocket, .phonon]
        }
        return [.apple, .kokoro, .supertonic3, .pocket]
        #endif
    }

    static var downloadableCases: [EbookTTSEngineChoice] {
        allCases.filter { $0 != .apple }
    }

    var displayName: String {
        switch self {
        case .apple: "Apple voices"
        case .kokoro: "Kokoro"
        case .supertonic3: "Supertonic 3"
        case .pocket: "Pocket TTS"
        case .phonon: "Phonon"
        }
    }

    var detail: String {
        switch self {
        case .apple: "Built into your iPhone"
        case .kokoro: "Natural English · private and offline"
        case .supertonic3: "Multilingual · private and offline"
        case .pocket: "Alba · English · private and offline"
        case .phonon: "British English · private and offline"
        }
    }

    var modelName: String {
        switch self {
        case .apple: ""
        case .kokoro: "Kokoro"
        case .supertonic3: "Supertonic 3"
        case .pocket: "Pocket TTS"
        case .phonon: "Phonon"
        }
    }

    var modelSummary: String {
        switch self {
        case .apple: ""
        case .kokoro: "English · 4 voices · Apache 2.0"
        case .supertonic3: "31 languages · 10 voices"
        case .pocket: "English · Alba MacKenna"
        case .phonon: "British English · 2 voices · Apache 2.0"
        }
    }

    var license: (title: String, url: URL)? {
        switch self {
        case .apple, .kokoro: nil
        case .supertonic3:
            ("Supertonic model license and use terms", URL(string: "https://huggingface.co/Supertone/supertonic-3/blob/main/LICENSE")!)
        case .phonon:
            ("Gradium Phonon 31m · Apache 2.0", URL(string: "https://huggingface.co/gradium/phonon-31m-en")!)
        case .pocket:
            ("Kyutai and Alba MacKenna · CC BY 4.0", URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
        }
    }
}

nonisolated enum TTSModelDownloadState: Equatable, Sendable {
    case notDownloaded
    case downloading(Double)
    case cancelling
    case removing
    case ready
    case failed(String)

    var isTransferring: Bool {
        switch self {
        case .downloading, .cancelling, .removing: true
        case .notDownloaded, .ready, .failed: false
        }
    }
}
