import Foundation

#if canImport(UIKit)
import UIKit
#endif

struct PlexPin: Codable {
    let id: String
    let code: String
    let authToken: String?
    let expiresAt: Date?
    let clientIdentifier: String?

    var authURL: URL? {
        let clientID = clientIdentifier ?? "enve-ios"
        let product =
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Enve"

        var deviceName = "Unknown Device"
        var systemVersion = "1.0"
        var platform = "iOS"
        var model = "Unknown Model"

        #if canImport(UIKit)
        let device = UIDevice.current
        deviceName = device.name
        systemVersion = device.systemVersion
        model = device.model
        #elseif os(macOS)
        deviceName = Host.current().localizedName ?? "Mac"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        systemVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        platform = "macOS"
        model = "Mac"
        #endif

        let params = [
            "clientID=\(clientID)",
            "code=\(code)",
            "context%5Bdevice%5D%5Bproduct%5D=\(product.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")",
            "context%5Bdevice%5D%5Bdevice%5D=\(deviceName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")",
            "context%5Bdevice%5D%5Bplatform%5D=\(platform)",
            "context%5Bdevice%5D%5BplatformVersion%5D=\(systemVersion)",
            "context%5Bdevice%5D%5Bmodel%5D=\(model.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")",
        ].joined(separator: "&")
        let urlString = "https://app.plex.tv/auth#?\(params)"
        return URL(string: urlString)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case code
        case authToken
        case expiresAt
        case clientIdentifier
    }

    init(id: String, code: String, authToken: String?, expiresAt: Date?, clientIdentifier: String?) {
        self.id = id
        self.code = code
        self.authToken = authToken
        self.expiresAt = expiresAt
        self.clientIdentifier = clientIdentifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        code = try container.decode(String.self, forKey: .code)
        authToken = try container.decodeIfPresent(String.self, forKey: .authToken)
        clientIdentifier = try container.decodeIfPresent(String.self, forKey: .clientIdentifier)

        if let expiresTimestamp = try? container.decodeIfPresent(Int.self, forKey: .expiresAt) {
            expiresAt = Date(timeIntervalSince1970: TimeInterval(expiresTimestamp))
        } else {
            expiresAt = nil
        }
    }
}
