import Combine
import Foundation

@MainActor
@Observable
final class EbookDownloadProgressStore {
    static let shared = EbookDownloadProgressStore()

    private(set) var activeDownloads: [String: Double] = [:]
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    private init() {

        UnifiedDownloadService.shared.$tasks
            .sink { [weak self] tasks in
                guard let self else { return }
                var next: [String: Double] = [:]
                for t in tasks where t.isActive {
                    next[t.bookId] = t.progress
                }
                self.activeDownloads = next
            }
            .store(in: &cancellables)
    }

    func progress(for bookId: String) -> Double? {
        activeDownloads[bookId]
    }
}
