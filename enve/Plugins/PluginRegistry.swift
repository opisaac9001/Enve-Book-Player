import Foundation

typealias LibraryProviderFactory = (ServerConnection) -> LibraryProvider

@MainActor
final class PluginRegistry {
    static let shared = PluginRegistry()

    private(set) var sinks: [any SyncSink] = []
    private(set) var syncStrategies: [any ProviderSyncStrategy] = []
    private var libraryProviderFactories: [ProviderType: LibraryProviderFactory] = [:]

    private init() {}

    func register(sink: any SyncSink) {
        guard !sinks.contains(where: { $0.id == sink.id }) else { return }
        sinks.append(sink)
    }

    func unregister(sinkId: String) {
        sinks.removeAll { $0.id == sinkId }
    }

    func sinks(
        applicableTo book: Book,
        domain: ProgressSyncDomain
    ) -> [any SyncSink] {
        sinks.filter { $0.isApplicable(to: book, domain: domain) }
    }

    func register(syncStrategy: any ProviderSyncStrategy) {
        guard !syncStrategies.contains(where: { $0.id == syncStrategy.id }) else { return }
        syncStrategies.append(syncStrategy)
    }

    func unregister(syncStrategyId: String) {
        syncStrategies.removeAll { $0.id == syncStrategyId }
    }

    func register(libraryProviderFactory factory: @escaping LibraryProviderFactory, for type: ProviderType) {
        libraryProviderFactories[type] = factory
    }

    func makeLibraryProvider(for connection: ServerConnection) -> LibraryProvider? {
        libraryProviderFactories[connection.type]?(connection)
    }

    func makeCapability<Capability>(
        _ capability: Capability.Type,
        for connection: ServerConnection
    ) -> Capability? {
        makeLibraryProvider(for: connection) as? Capability
    }

    var registeredProviderTypes: Set<ProviderType> {
        Set(libraryProviderFactories.keys)
    }
}
