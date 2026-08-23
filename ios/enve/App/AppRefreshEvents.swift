import Foundation

enum AppRefreshEvents {
    static func stream(
        names: [Notification.Name],
        debounce: Duration = .milliseconds(900)
    ) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                let hub = RefreshEventHub(
                    names: names,
                    debounce: debounce,
                    continuation: continuation
                )
                await hub.run()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

@MainActor
private final class RefreshEventHub {
    private let names: [Notification.Name]
    private let debounce: Duration
    private let continuation: AsyncStream<Void>.Continuation
    private var pending: Task<Void, Never>?

    init(
        names: [Notification.Name],
        debounce: Duration,
        continuation: AsyncStream<Void>.Continuation
    ) {
        self.names = names
        self.debounce = debounce
        self.continuation = continuation
    }

    func run() async {
        await withTaskGroup(of: Void.self) { group in
            for name in names {
                group.addTask { [weak self] in
                    for await _ in NotificationCenter.default.notifications(named: name) {
                        guard !Task.isCancelled else { return }
                        await self?.scheduleYield()
                    }
                }
            }
            await group.waitForAll()
        }
    }

    private func scheduleYield() {
        pending?.cancel()
        pending = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            continuation.yield(())
        }
    }
}
