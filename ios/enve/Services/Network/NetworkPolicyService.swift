// AGENT-LOCKED
import Combine
import Foundation
import Logging
import Network

final class NetworkPolicyService: @unchecked Sendable {
    static let shared = NetworkPolicyService()

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.narrator.NetworkPolicyService.monitor")

    @Published private(set) var isExpensive: Bool = false
    @Published private(set) var isConnected: Bool = false

    private var cancellables = Set<AnyCancellable>()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isExpensive = path.isExpensive
                self?.isConnected = path.status == .satisfied
                AppLogger.network.info(
                    "NetworkPolicyService: connected=\(path.status == .satisfied), expensive=\(path.isExpensive), status=\(path.status)"
                )
            }
        }
        monitor.start(queue: monitorQueue)
    }

    func canDownload(allowCellular: Bool) -> Bool {
        AppLogger.network.info(
            "NetworkPolicyService.canDownload: isConnected=\(isConnected), isExpensive=\(isExpensive), allowCellular=\(allowCellular)"
        )
        guard isConnected else {
            AppLogger.network.info("Not connected")
            return false
        }
        guard isExpensive else {
            AppLogger.network.info("Wi-Fi - allowed")
            return true
        }
        let result = allowCellular
        AppLogger.network.info("Cellular network: allowCellular=\(allowCellular), result=\(result)")
        return result
    }

    func makeSessionConfiguration(allowCellular: Bool) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.allowsConstrainedNetworkAccess = false
        config.allowsExpensiveNetworkAccess = allowCellular
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3600
        return config
    }

    func makeBackgroundSessionConfiguration(
        identifier: String,
        allowCellular: Bool
    ) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.waitsForConnectivity = true
        config.allowsConstrainedNetworkAccess = false
        config.allowsExpensiveNetworkAccess = allowCellular
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3600
        return config
    }
}
