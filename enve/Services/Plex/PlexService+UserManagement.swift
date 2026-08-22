import Foundation
import Logging

extension PlexService {

    func getSharedUsers(token: String) async throws -> [PlexManagedUser] {
        guard let url = URL(string: "\(baseURL)/api/users/") else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyPlexHeaders(&request, token: token)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexError.serverUnreachable
        }
        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw PlexError.invalidToken
            }
            throw PlexError.unknownStatusCode(httpResponse.statusCode)
        }

        return try parseSharedUsersXML(data: data)
    }

    func removeSharedUser(token: String, userId: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/v2/sharings/\(userId)") else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyPlexHeaders(&request, token: token)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw PlexError.unknownStatusCode(code)
        }
    }

    func getManagedUsers(serverUrl: String, token: String) async throws -> [PlexManagedUser] {
        guard let baseURL = URL(string: serverUrl),
            let url = URL(string: "/accounts", relativeTo: baseURL)
        else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyPlexHeaders(&request, token: token)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw PlexError.serverUnreachable
            }

            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    throw PlexError.invalidToken
                }
                throw PlexError.unknownStatusCode(httpResponse.statusCode)
            }

            let decoder = JSONDecoder()
            let usersResponse = try decoder.decode(PlexUsersResponseWrapper.self, from: data)
            return usersResponse.MediaContainer?.Account ?? []
        } catch let error as PlexError {
            throw error
        } catch {
            throw PlexError.decodingError(error)
        }
    }

    func createManagedUser(serverUrl: String, token: String, username: String, pin: String? = nil) async throws -> PlexManagedUser {
        guard let baseURL = URL(string: serverUrl),
            let url = URL(string: "/accounts", relativeTo: baseURL)
        else {
            throw PlexError.invalidURL
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        var queryItems = [URLQueryItem(name: "title", value: username)]
        if let pin = pin, !pin.isEmpty {
            queryItems.append(URLQueryItem(name: "pin", value: pin))
        }
        components?.queryItems = queryItems

        guard let createURL = components?.url else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: createURL)
        request.httpMethod = "POST"
        applyPlexHeaders(&request, token: token)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                (200...299).contains(httpResponse.statusCode)
            else {
                throw PlexError.serverUnreachable
            }

            let decoder = JSONDecoder()
            let userResponse = try decoder.decode(PlexUserResponseWrapper.self, from: data)
            guard let user = userResponse.Account else {
                throw PlexError.decodingError(
                    NSError(domain: "PlexService", code: -1, userInfo: [NSLocalizedDescriptionKey: "User not found in response"])
                )
            }
            return user
        } catch let error as PlexError {
            throw error
        } catch {
            throw PlexError.decodingError(error)
        }
    }

    func deleteManagedUser(serverUrl: String, token: String, userId: String) async throws {
        guard let baseURL = URL(string: serverUrl),
            let url = URL(string: "/accounts/\(userId)", relativeTo: baseURL)
        else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyPlexHeaders(&request, token: token)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw PlexError.serverUnreachable
        }
    }

    func updateManagedUser(serverUrl: String, token: String, userId: String, restricted: Bool? = nil, pin: String? = nil) async throws {
        guard let baseURL = URL(string: serverUrl),
            let url = URL(string: "/accounts/\(userId)", relativeTo: baseURL)
        else {
            throw PlexError.invalidURL
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        var queryItems: [URLQueryItem] = []
        if let restricted = restricted {
            queryItems.append(URLQueryItem(name: "restricted", value: restricted ? "1" : "0"))
        }
        if let pin = pin {
            queryItems.append(URLQueryItem(name: "pin", value: pin))
        }
        components?.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let updateURL = components?.url else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: updateURL)
        request.httpMethod = "PUT"
        applyPlexHeaders(&request, token: token)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw PlexError.serverUnreachable
        }
    }

    func inviteUserToServer(
        token: String,
        serverId: String,
        email: String,
        sectionIds: [String],
        allowSync: Bool,
        allowCameraUpload: Bool = false,
        allowChannels: Bool = false
    ) async throws {
        let plexSectionIds = try await translateToPlexSectionIds(
            token: token,
            machineId: serverId,
            localSectionKeys: sectionIds
        )
        try await postSharedServer(
            token: token,
            serverId: serverId,
            recipient: .email(email),
            plexSectionIds: plexSectionIds,
            allowSync: allowSync,
            allowCameraUpload: allowCameraUpload,
            allowChannels: allowChannels
        )
    }

    func createHomeUser(
        token: String,
        serverId: String,
        username: String,
        pin: String?,
        sectionIds: [String],
        allowSync: Bool,
        allowCameraUpload: Bool = false,
        allowChannels: Bool = false
    ) async throws {
        guard let createURL = URL(string: "\(baseURL)/api/v2/home/users") else {
            throw PlexError.invalidURL
        }

        var createRequest = URLRequest(url: createURL)
        createRequest.httpMethod = "POST"
        createRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        createRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyPlexHeaders(&createRequest, token: token)

        var createBody: [String: Any] = ["title": username]
        if let pin, !pin.isEmpty { createBody["pin"] = pin }
        createRequest.httpBody = try JSONSerialization.data(withJSONObject: createBody)

        let (createData, createResponse) = try await session.data(for: createRequest)
        let createStatus = (createResponse as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(createStatus) else {
            let body = String(data: createData, encoding: .utf8)
            AppLogger.network.error("Plex create home user failed (\(createStatus)) url=\(createURL.redacted)")
            throw PlexError.httpError(code: createStatus, body: body)
        }

        guard let json = try? JSONSerialization.jsonObject(with: createData) as? [String: Any],
            let numericId = json["id"]
        else {
            AppLogger.network.error("Plex home user created but could not parse user ID")
            return
        }
        let userId = "\(numericId)"
        AppLogger.network.info("Plex home user created: id=\(userId)")

        guard !sectionIds.isEmpty, let invitedId = Int(userId) else { return }

        let plexSectionIds = try await translateToPlexSectionIds(
            token: token,
            machineId: serverId,
            localSectionKeys: sectionIds
        )
        try await postSharedServer(
            token: token,
            serverId: serverId,
            recipient: .invitedId(invitedId),
            plexSectionIds: plexSectionIds,
            allowSync: allowSync,
            allowCameraUpload: allowCameraUpload,
            allowChannels: allowChannels
        )
        AppLogger.network.info("Libraries shared with home user \(userId)")
    }

    private enum InviteRecipient {
        case email(String)
        case invitedId(Int)
    }

    private func postSharedServer(
        token: String,
        serverId: String,
        recipient: InviteRecipient,
        plexSectionIds: [Int],
        allowSync: Bool,
        allowCameraUpload: Bool,
        allowChannels: Bool
    ) async throws {
        guard let url = URL(string: "\(baseURL)/api/servers/\(serverId)/shared_servers") else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyPlexHeaders(&request, token: token)

        var sharedServer: [String: Any] = ["library_section_ids": plexSectionIds]
        switch recipient {
        case .email(let email): sharedServer["invited_email"] = email
        case .invitedId(let id): sharedServer["invited_id"] = id
        }

        let payload: [String: Any] = [
            "server_id": serverId,
            "shared_server": sharedServer,
            "sharing_settings": [
                "allowSync": allowSync ? "1" : "0",
                "allowCameraUpload": allowCameraUpload ? "1" : "0",
                "allowChannels": allowChannels ? "1" : "0",
                "filterMovies": "",
                "filterTelevision": "",
                "filterMusic": "",
            ],
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexError.serverUnreachable
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            AppLogger.network.error("Plex invite failed (\(httpResponse.statusCode)) url=\(url.redacted) sections=\(plexSectionIds)")
            throw PlexError.httpError(code: httpResponse.statusCode, body: body)
        }
    }

    private func translateToPlexSectionIds(
        token: String,
        machineId: String,
        localSectionKeys: [String]
    ) async throws -> [Int] {
        guard let url = URL(string: "\(baseURL)/api/servers/\(machineId)") else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        applyPlexHeaders(&request, token: token)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexError.serverUnreachable
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            AppLogger.network.error("Plex section lookup failed (\(httpResponse.statusCode)) url=\(url.redacted)")
            throw PlexError.httpError(code: httpResponse.statusCode, body: body)
        }

        let parser = PlexServerSectionsXMLParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else {
            throw PlexError.decodingError(parser.parseError ?? NSError(domain: "PlexSectionXML", code: -1))
        }

        let localKeySet = Set(localSectionKeys)
        let translated = parser.sections
            .filter { localKeySet.contains(String($0.key)) }
            .map(\.id)

        if translated.isEmpty, !localSectionKeys.isEmpty {
            AppLogger.network.warning(
                "Plex section translation produced 0 IDs; local keys=\(localSectionKeys), parsed=\(parser.sections.map { "key=\($0.key) id=\($0.id)" })"
            )
        }
        return translated
    }
}

private struct PlexServerSection {
    let id: Int
    let key: Int
}

private final class PlexServerSectionsXMLParser: NSObject, XMLParserDelegate {
    var sections: [PlexServerSection] = []
    var parseError: Error?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "Section",
            let idStr = attributeDict["id"], let id = Int(idStr),
            let keyStr = attributeDict["key"], let key = Int(keyStr)
        else { return }
        sections.append(PlexServerSection(id: id, key: key))
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}

private struct PlexUsersResponseWrapper: Codable {
    let MediaContainer: PlexUsersContainer?
}

private struct PlexUsersContainer: Codable {
    let Account: [PlexManagedUser]?
}

private struct PlexUserResponseWrapper: Codable {
    let Account: PlexManagedUser?
}

private func parseSharedUsersXML(data: Data) throws -> [PlexManagedUser] {
    let parser = XMLParser(data: data)
    let delegate = PlexSharedUsersXMLParser()
    parser.delegate = delegate
    guard parser.parse() else {
        if let error = delegate.parseError {
            throw PlexError.decodingError(error)
        }
        throw PlexError.decodingError(
            NSError(domain: "XMLParser", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse /api/users/ XML"])
        )
    }
    return delegate.users
}

private class PlexSharedUsersXMLParser: NSObject, XMLParserDelegate {
    var users: [PlexManagedUser] = []
    var parseError: Error?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "User" else { return }

        guard let id = attributeDict["id"], !id.isEmpty else { return }

        let user = PlexManagedUser(
            id: id,
            username: attributeDict["username"],
            email: attributeDict["email"],
            thumb: attributeDict["thumb"],
            hasPassword: nil,
            restricted: parseBool(attributeDict["restricted"]),
            home: parseBool(attributeDict["home"]),
            title: attributeDict["title"]
        )
        users.append(user)
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }

    private func parseBool(_ value: String?) -> Bool? {
        guard let value else { return nil }
        return value == "1" || value.lowercased() == "true"
    }
}
