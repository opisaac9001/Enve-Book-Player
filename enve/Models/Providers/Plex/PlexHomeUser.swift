import Foundation

public struct PlexHomeUser: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let uuid: String?
    public let title: String
    public let username: String?
    public let email: String?
    public let thumb: String?
    public let isAdmin: Bool
    public let isManaged: Bool
    public let isRestricted: Bool
    public let hasPin: Bool
    public let isGuest: Bool

    public var displayName: String {
        if !title.isEmpty { return title }
        if let username, !username.isEmpty { return username }
        if let email, !email.isEmpty { return email }
        return "User \(id)"
    }
}

struct PlexHomeUsersResponse: Codable {
    let id: Int?
    let guestEnabled: Bool?
    let guestUserID: Int?
    let users: [PlexHomeUserRaw]?
}

struct PlexHomeUserRaw: Codable {
    let id: Int
    let uuid: String?
    let title: String?
    let username: String?
    let email: String?
    let thumb: String?
    let admin: Bool?
    let guest: Bool?
    let restricted: Bool?
    let restrictionProfile: String?
    let `protected`: Bool?
    let hasPassword: Bool?
    let home: Bool?

    func toPlexHomeUser() -> PlexHomeUser {
        PlexHomeUser(
            id: String(id),
            uuid: uuid,
            title: title ?? username ?? "User \(id)",
            username: username,
            email: email,
            thumb: thumb,
            isAdmin: admin ?? false,
            isManaged: (username == nil || username?.isEmpty == true) && (email == nil || email?.isEmpty == true),
            isRestricted: restricted ?? (restrictionProfile != nil),
            hasPin: `protected` ?? hasPassword ?? false,
            isGuest: guest ?? false
        )
    }
}

struct PlexSwitchUserResponse {
    let id: Int?
    let uuid: String?
    let authToken: String?
    let title: String?
    let username: String?
    let thumb: String?
}

final class PlexSwitchUserXMLDelegate: NSObject, XMLParserDelegate {
    var result: PlexSwitchUserResponse?
    var parseError: Error?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard result == nil else { return }

        let authToken = attributeDict["authenticationToken"] ?? attributeDict["authToken"]
        guard authToken != nil else { return }

        let idStr = attributeDict["id"]
        result = PlexSwitchUserResponse(
            id: idStr.flatMap { Int($0) },
            uuid: attributeDict["uuid"],
            authToken: authToken,
            title: attributeDict["title"],
            username: attributeDict["username"],
            thumb: attributeDict["thumb"]
        )
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}
