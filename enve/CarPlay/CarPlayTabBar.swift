@preconcurrency import CarPlay
import Combine
import Foundation

@MainActor
final class CarPlayTabBar: NSObject {
    private let interfaceController: CPInterfaceController
    private let environment: CarPlayEnvironment
    private weak var nowPlaying: CarPlayNowPlaying?
    private var pages: [ObjectIdentifier: CarPlayPage] = [:]
    private var home: CarPlayHome?
    private var downloaded: CarPlayDownloaded?
    private var search: CarPlayLibrarySearch?
    private var cancellables = Set<AnyCancellable>()
    private var lastConnectionSignature: String?
    private(set) var tabBarTemplate: CPTemplate?

    private var connectionSignature: String {
        CarPlayCatalog.connectionSignature(environment.connections.connections)
    }

    init(interfaceController: CPInterfaceController, environment: CarPlayEnvironment, nowPlaying: CarPlayNowPlaying) {
        self.interfaceController = interfaceController
        self.environment = environment
        self.nowPlaying = nowPlaying
        super.init()

        interfaceController.delegate = self

        environment.connections.connectionsChanged
            .receive(on: RunLoop.main)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.connectionSignature != self.lastConnectionSignature {
                    self.buildAndSetRoot()
                }
            }
            .store(in: &cancellables)

        environment.library.libraryChanged
            .receive(on: RunLoop.main)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refreshVisibleTabs() }
            .store(in: &cancellables)
    }

    func buildAndSetRoot() {
        guard let nowPlaying else { return }
        lastConnectionSignature = connectionSignature

        let hasConnections = !environment.connections.connections.isEmpty

        let hasBooks = environment.library.cachedBookCount > 0

        let newTemplate: CPTemplate

        if hasConnections || hasBooks {
            let homeInstance = CarPlayHome(
                interfaceController: interfaceController,
                environment: environment,
                nowPlaying: nowPlaying
            )
            let downloadedInstance = CarPlayDownloaded(
                interfaceController: interfaceController,
                environment: environment,
                nowPlaying: nowPlaying
            )
            let searchInstance = CarPlayLibrarySearch(
                interfaceController: interfaceController,
                environment: environment,
                nowPlaying: nowPlaying
            )
            home = homeInstance
            downloaded = downloadedInstance
            search = searchInstance
            var newPages: [ObjectIdentifier: CarPlayPage] = [:]
            for page in [homeInstance, downloadedInstance, searchInstance] as [CarPlayPage] {
                newPages[ObjectIdentifier(page.template)] = page
            }
            pages = newPages
            newTemplate = CPTabBarTemplate(templates: [homeInstance.template, downloadedInstance.template, searchInstance.template])
        } else {
            home = nil
            downloaded = nil
            search = nil
            pages = [:]
            newTemplate = Self.emptyTemplate
        }

        tabBarTemplate = newTemplate
        interfaceController.setRootTemplate(newTemplate, animated: false, completion: nil)
    }

    private func refreshVisibleTabs() {

        home?.willAppear()
    }

    private static var emptyTemplate: CPListTemplate {
        let t = CPListTemplate(title: "Enve", sections: [])
        t.emptyViewTitleVariants = ["Not Connected"]
        t.emptyViewSubtitleVariants = ["Add a server in the Enve app to get started"]
        return t
    }
}

extension CarPlayTabBar: CPInterfaceControllerDelegate {
    func templateWillAppear(_ template: CPTemplate, animated: Bool) {
        pages[ObjectIdentifier(template)]?.willAppear()
    }
}
