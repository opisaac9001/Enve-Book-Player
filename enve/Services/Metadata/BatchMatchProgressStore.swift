import Foundation

@MainActor
@Observable
final class BatchMatchProgressStore {
    static let shared = BatchMatchProgressStore()

    private(set) var isMatching: Bool = false
    private(set) var progress: (current: Int, total: Int)?
    private(set) var lastResult: BatchMatchResult?
    private(set) var lastLibraryName: String?
    private(set) var currentProvider: MetadataProvider?

    private(set) var completionToken: UUID = UUID()

    @ObservationIgnored private var matchingTask: Task<Void, Never>?

    private init() {}

    func start(libraryName: String, provider: MetadataProvider) {
        isMatching = true
        progress = (current: 0, total: 0)
        lastResult = nil
        lastLibraryName = libraryName
        currentProvider = provider
    }

    func setTask(_ task: Task<Void, Never>) {
        matchingTask = task
    }

    func stop() {
        matchingTask?.cancel()
        matchingTask = nil
        isMatching = false
        progress = nil
        currentProvider = nil
    }

    func setTotal(_ total: Int) {
        if progress == nil {
            progress = (current: 0, total: total)
        } else {
            progress = (current: progress?.current ?? 0, total: total)
        }
    }

    func updateProgress(current: Int, total: Int) {
        progress = (current: current, total: total)
    }

    func finish(result: BatchMatchResult) {
        matchingTask = nil
        isMatching = false
        progress = nil
        currentProvider = nil
        lastResult = result
        completionToken = UUID()
    }

    func fail() {
        matchingTask = nil
        isMatching = false
        progress = nil
        currentProvider = nil
        completionToken = UUID()
    }
}
