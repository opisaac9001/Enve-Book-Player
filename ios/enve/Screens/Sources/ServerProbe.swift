import Foundation

struct DetectedServer: Identifiable {
    let providerType: ProviderType
    let displayName: String
    let normalizedURL: String
    let oidcEnabled: Bool
    let recommendedAuth: UnifiedAuthMethod

    var id: String { providerType.rawValue + "|" + normalizedURL }
}

enum ServerProbeOutcome {

    case identified(DetectedServer)

    case oidcIssuerOnly(normalizedURL: String)

    case unknown(normalizedURL: String)

    case unreachable
}

enum ServerProbe {

    static func detect(rawURL: String) async -> ServerProbeOutcome {
        let bases = candidateBases(from: rawURL)
        guard !bases.isEmpty else { return .unreachable }

        var reachableBase: String?
        for base in bases {
            if let detected = await identify(base) {
                return .identified(detected)
            }
            if let issuer = await oidcIssuer(at: base) {
                return .oidcIssuerOnly(normalizedURL: issuer)
            }
            if reachableBase == nil, await isReachable(base) {
                reachableBase = base
            }
        }

        if let reachableBase { return .unknown(normalizedURL: reachableBase) }
        return .unreachable
    }

    private static func identify(_ base: String) async -> DetectedServer? {

        async let abs = fingerprintAudiobookshelf(base)
        async let grimmory = fingerprintGrimmory(base)
        async let bookOrbit = fingerprintBookOrbit(base)
        async let silo = fingerprintSilo(base)
        async let komga = fingerprintKomga(base)
        async let plex = fingerprintPlex(base)
        async let jellyfinEmby = fingerprintJellyfinEmby(base)
        async let storyteller = fingerprintStoryteller(base)
        async let kavita = fingerprintKavita(base)
        async let opds = fingerprintOPDS(base)

        let ordered: [DetectedServer?] = [
            await abs, await grimmory, await bookOrbit, await silo, await komga,
            await plex, await jellyfinEmby, await storyteller, await kavita, await opds,
        ]
        return ordered.compactMap { $0 }.first
    }

    private struct ABSStatus: Decodable {
        let app: String?
        let authMethods: [String]?
    }

    private static func fingerprintAudiobookshelf(_ base: String) async -> DetectedServer? {
        guard let (resp, data) = await get(base, "/status"), resp.statusCode == 200,
            let status = try? JSONDecoder().decode(ABSStatus.self, from: data),
            status.app?.lowercased() == "audiobookshelf"
        else { return nil }
        let oidc = (status.authMethods ?? []).contains { $0.lowercased().contains("openid") }
        return DetectedServer(
            providerType: .audiobookshelf,
            displayName: "Audiobookshelf",
            normalizedURL: base,
            oidcEnabled: oidc,
            recommendedAuth: oidc ? .oidc : .usernamePassword
        )
    }

    private struct GrimmorySettings: Decodable {
        let oidcEnabled: Bool
    }

    private static func fingerprintGrimmory(_ base: String) async -> DetectedServer? {
        guard let (resp, data) = await get(base, "/api/v1/public-settings"), resp.statusCode == 200,
            let settings = try? JSONDecoder().decode(GrimmorySettings.self, from: data)
        else { return nil }
        return DetectedServer(
            providerType: .booklore,
            displayName: "Grimmory",
            normalizedURL: base,
            oidcEnabled: settings.oidcEnabled,
            recommendedAuth: settings.oidcEnabled ? .oidc : .usernamePassword
        )
    }

    private struct BookOrbitProvider: Decodable {
        let slug: String?
    }

    private static func fingerprintBookOrbit(_ base: String) async -> DetectedServer? {
        guard let (resp, data) = await get(base, "/api/v1/app-settings/oidc/providers/public"),
            resp.statusCode == 200,
            let providers = try? JSONDecoder().decode([BookOrbitProvider].self, from: data)
        else { return nil }
        let oidc = !providers.isEmpty
        return DetectedServer(
            providerType: .bookOrbit,
            displayName: "BookOrbit",
            normalizedURL: base,
            oidcEnabled: oidc,
            recommendedAuth: oidc ? .oidc : .usernamePassword
        )
    }

    private struct SiloHealth: Decodable {
        let status: String?
        let serverID: String?

        enum CodingKeys: String, CodingKey {
            case status
            case serverID = "server_id"
        }
    }

    private static func fingerprintSilo(_ base: String) async -> DetectedServer? {

        guard let (resp, data) = await get(base, "/api/v1/health"), resp.statusCode == 200,
            let health = try? JSONDecoder().decode(SiloHealth.self, from: data),
            health.status?.lowercased() == "ok",
            health.serverID?.isEmpty == false
        else { return nil }
        return DetectedServer(
            providerType: .silo,
            displayName: "Silo",
            normalizedURL: base,
            oidcEnabled: false,
            recommendedAuth: .usernamePassword
        )
    }

    private struct KomgaClaim: Decodable {
        let isClaimed: Bool
    }

    private static func fingerprintKomga(_ base: String) async -> DetectedServer? {
        guard let (resp, data) = await get(base, "/api/v1/claim"), resp.statusCode == 200,
            (try? JSONDecoder().decode(KomgaClaim.self, from: data)) != nil
        else { return nil }
        let oidc = await komgaHasOIDC(base)
        return DetectedServer(
            providerType: .komga,
            displayName: "Komga",
            normalizedURL: base,
            oidcEnabled: oidc,
            recommendedAuth: oidc ? .oidc : .usernamePassword
        )
    }

    private static func komgaHasOIDC(_ base: String) async -> Bool {
        guard let (resp, data) = await get(base, "/api/v1/oauth2/providers"), resp.statusCode == 200 else { return false }
        if let array = try? JSONSerialization.jsonObject(with: data) as? [Any] { return !array.isEmpty }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return !object.isEmpty }
        return false
    }

    private static func fingerprintPlex(_ base: String) async -> DetectedServer? {
        guard let (resp, data) = await get(base, "/identity", accept: "application/json"),
            resp.statusCode == 200,
            let body = String(data: data, encoding: .utf8)?.lowercased(),
            body.contains("machineidentifier")
        else { return nil }
        return DetectedServer(
            providerType: .plex,
            displayName: "Plex",
            normalizedURL: base,
            oidcEnabled: false,
            recommendedAuth: .usernamePassword
        )
    }

    private struct PublicSystemInfo: Decodable {
        let ProductName: String?
        let ServerName: String?
        let Version: String?
        let Id: String?
    }

    private static func fingerprintJellyfinEmby(_ base: String) async -> DetectedServer? {
        let lowerBase = base.lowercased()
        let apiBases =
            lowerBase.hasSuffix("/emby")
            ? [(url: base, isEmbyAPIBase: true)]
            : [(url: base, isEmbyAPIBase: false), (url: base + "/emby", isEmbyAPIBase: true)]

        for apiBase in apiBases {
            guard let (resp, data) = await get(apiBase.url, "/System/Info/Public"),
                resp.statusCode == 200
            else { continue }

            let info = try? JSONDecoder().decode(PublicSystemInfo.self, from: data)
            var product = (info?.ProductName ?? "").lowercased()
            if product.isEmpty, let text = String(data: data, encoding: .utf8)?.lowercased() {
                product = text
            }
            if product.contains("jellyfin") {
                return DetectedServer(
                    providerType: .jellyfin,
                    displayName: "Jellyfin",
                    normalizedURL: apiBase.url,
                    oidcEnabled: false,
                    recommendedAuth: .usernamePassword
                )
            }
            if product.contains("emby") || (apiBase.isEmbyAPIBase && isValidPublicSystemInfo(info)) {
                return DetectedServer(
                    providerType: .emby,
                    displayName: "Emby",
                    normalizedURL: apiBase.url,
                    oidcEnabled: false,
                    recommendedAuth: .usernamePassword
                )
            }
        }
        return nil
    }

    private static func isValidPublicSystemInfo(_ info: PublicSystemInfo?) -> Bool {
        guard let info else { return false }
        return info.ServerName?.isEmpty == false
            && info.Version?.isEmpty == false
            && info.Id?.isEmpty == false
    }

    private static func fingerprintStoryteller(_ base: String) async -> DetectedServer? {

        if let (resp, data) = await get(base, "/api/v2/auth/providers"), resp.statusCode == 200,
            let providers = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            providers["credentials"] != nil
        {
            let sso = providers.keys.contains { $0.lowercased() != "credentials" }
            return DetectedServer(
                providerType: .storyteller,
                displayName: "Storyteller",
                normalizedURL: base,
                oidcEnabled: sso,
                recommendedAuth: sso ? .webLogin : .usernamePassword
            )
        }
        guard let (resp, data) = await get(base, "/api"), resp.statusCode == 200,
            let body = String(data: data, encoding: .utf8)?.lowercased(),
            body.contains("\"hello\"") || body.contains("storyteller")
        else { return nil }
        return DetectedServer(
            providerType: .storyteller,
            displayName: "Storyteller",
            normalizedURL: base,
            oidcEnabled: false,
            recommendedAuth: .usernamePassword
        )
    }

    private static func fingerprintKavita(_ base: String) async -> DetectedServer? {
        guard let (resp, data) = await get(base, "/api/health"), resp.statusCode == 200 else { return nil }
        let body = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard body == "ok" || body == "healthy" else { return nil }
        return DetectedServer(
            providerType: .kavita,
            displayName: "Kavita",
            normalizedURL: base,
            oidcEnabled: false,
            recommendedAuth: .usernamePassword
        )
    }

    private static func fingerprintOPDS(_ base: String) async -> DetectedServer? {
        guard let (resp, data) = await get(base, ""), resp.statusCode == 200 else { return nil }
        let contentType = (resp.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let body = String(data: data.prefix(2048), encoding: .utf8)?.lowercased() ?? ""
        let isOPDS =
            contentType.contains("atom+xml") || contentType.contains("opds")
            || (body.contains("<feed") && body.contains("www.w3.org/2005/atom"))
        guard isOPDS else { return nil }
        return DetectedServer(
            providerType: .opds,
            displayName: "OPDS",
            normalizedURL: base,
            oidcEnabled: false,
            recommendedAuth: .usernamePassword
        )
    }

    private struct OIDCDiscovery: Decodable {
        let issuer: String
        let authorization_endpoint: String
    }

    private static func oidcIssuer(at base: String) async -> String? {
        guard let (resp, data) = await get(base, "/.well-known/openid-configuration"),
            resp.statusCode == 200,
            (try? JSONDecoder().decode(OIDCDiscovery.self, from: data)) != nil
        else { return nil }
        return base
    }

    private static func isReachable(_ base: String) async -> Bool {
        await get(base, "") != nil
    }

    private static func get(
        _ base: String,
        _ path: String,
        accept: String? = nil,
        timeout: TimeInterval = 6
    ) async -> (HTTPURLResponse, Data)? {
        guard let url = URL(string: base + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        do {
            let (data, response) = try await InsecureURLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            return (http, data)
        } catch {
            return nil
        }
    }

    private static func candidateBases(from raw: String) -> [String] {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        guard !value.isEmpty else { return [] }
        let lower = value.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return [value, alternateScheme(for: value)].compactMap { $0 }
        }

        guard let preferred = ServerURLNormalizer.normalize(rawURL: value, providerType: .emby)?.absoluteString else {
            return []
        }
        return [preferred, alternateScheme(for: preferred)].compactMap { $0 }
    }

    private static func alternateScheme(for value: String) -> String? {
        if value.lowercased().hasPrefix("https://") {
            return "http://" + String(value.dropFirst("https://".count))
        }
        if value.lowercased().hasPrefix("http://") {
            return "https://" + String(value.dropFirst("http://".count))
        }
        return nil
    }
}
