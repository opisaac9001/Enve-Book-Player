import Foundation

struct JellyfinResponseError: LocalizedError {
    let statusCode: Int

    var errorDescription: String? { "Jellyfin request failed: HTTP \(statusCode)" }

    static func requireOK(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard response.statusCode != 401 else { throw ProviderError.unauthorized }
        guard response.statusCode == 200 else { throw Self(statusCode: response.statusCode) }
    }
}
