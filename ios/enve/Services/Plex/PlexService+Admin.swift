import Foundation
import Logging

extension PlexService {
    func getActiveSessions(serverUrl: String, token: String) async throws -> [PlexActiveSession] {
        guard let baseURL = URL(string: serverUrl),
            let url = URL(string: "/status/sessions", relativeTo: baseURL)
        else {
            throw PlexError.invalidURL
        }

        AppLogger.network.info("Fetching active sessions from: \(url.redacted)")

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyPlexHeaders(&request, token: token)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200
            else {
                AppLogger.network.info("Sessions endpoint returned status: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                throw PlexError.serverUnreachable
            }

            let decoder = JSONDecoder()
            let sessionsResponse = try decoder.decode(PlexSessionsResponseWrapper.self, from: data)
            let sessions = sessionsResponse.MediaContainer?.Metadata ?? []
            AppLogger.network.info("Parsed \(sessions.count) active sessions")
            return sessions
        } catch let error as PlexError {
            throw error
        } catch let error as DecodingError {
            AppLogger.network.error("Plex sessions JSON decode failed, trying to parse as XML")
            throw PlexError.decodingError(error)
        } catch {
            throw PlexError.networkError(error)
        }
    }

    func getAdminLibrarySections(serverUrl: String, token: String) async throws -> [PlexLibrarySection] {
        guard let baseURL = URL(string: serverUrl),
            let url = URL(string: "/library/sections", relativeTo: baseURL)
        else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyPlexHeaders(&request, token: token)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200
            else {
                throw PlexError.serverUnreachable
            }

            let decoder = JSONDecoder()
            let sectionsResponse = try decoder.decode(PlexSectionsResponseWrapper.self, from: data)
            return sectionsResponse.MediaContainer?.Directory ?? []
        } catch let error as PlexError {
            throw error
        } catch {
            throw PlexError.networkError(error)
        }
    }

    func refreshLibrary(serverUrl: String, token: String, sectionKey: String) async throws {
        guard let baseURL = URL(string: serverUrl),
            let url = URL(string: "/library/sections/\(sectionKey)/refresh", relativeTo: baseURL)
        else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyPlexHeaders(&request, token: token)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw PlexError.serverUnreachable
        }
    }

    func optimizeDatabase(serverUrl: String, token: String) async throws {
        guard let baseURL = URL(string: serverUrl),
            let url = URL(string: "/library/optimize", relativeTo: baseURL)
        else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        applyPlexHeaders(&request, token: token)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw PlexError.serverUnreachable
        }
    }

    func emptyTrash(serverUrl: String, token: String, sectionKey: String) async throws {
        guard let baseURL = URL(string: serverUrl),
            let url = URL(string: "/library/sections/\(sectionKey)/emptyTrash", relativeTo: baseURL)
        else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        applyPlexHeaders(&request, token: token)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw PlexError.serverUnreachable
        }
    }

    func cleanBundles(serverUrl: String, token: String) async throws {
        guard let baseURL = URL(string: serverUrl),
            let url = URL(string: "/library/clean/bundles", relativeTo: baseURL)
        else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        applyPlexHeaders(&request, token: token)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw PlexError.serverUnreachable
        }
    }

    func getServerIdentity(serverUrl: String, token: String) async throws -> PlexServerInfo {
        guard let baseURL = URL(string: serverUrl),
            let url = URL(string: "/identity", relativeTo: baseURL)
        else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyPlexHeaders(&request, token: token)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200
            else {
                throw PlexError.serverUnreachable
            }

            let decoder = JSONDecoder()
            let identityResponse = try decoder.decode(PlexIdentityResponseWrapper.self, from: data)
            return identityResponse.MediaContainer
                ?? PlexServerInfo(
                    machineIdentifier: nil,
                    version: nil,
                    platform: nil,
                    platformVersion: nil,
                    updatedAt: nil,
                    transcoderActiveVideoSessions: nil
                )
        } catch let error as PlexError {
            throw error
        } catch {
            throw PlexError.networkError(error)
        }
    }

    func terminateSession(serverUrl: String, token: String, sessionId: String) async throws {
        guard let baseURL = URL(string: serverUrl),
            let url = URL(string: "/status/sessions/terminate", relativeTo: baseURL)
        else {
            throw PlexError.invalidURL
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.queryItems = [
            URLQueryItem(name: "sessionId", value: sessionId),
            URLQueryItem(name: "reason", value: "Admin requested termination"),
        ]

        guard let terminateURL = components?.url else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: terminateURL)
        request.httpMethod = "GET"
        applyPlexHeaders(&request, token: token)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw PlexError.serverUnreachable
        }
    }
}

private struct PlexSessionsResponseWrapper: Codable {
    let MediaContainer: PlexSessionsContainer?
}

private struct PlexSessionsContainer: Codable {
    let Metadata: [PlexActiveSession]?
}

private struct PlexSectionsResponseWrapper: Codable {
    let MediaContainer: PlexSectionsContainerWrapper?
}

private struct PlexSectionsContainerWrapper: Codable {
    let Directory: [PlexLibrarySection]?
}

private struct PlexIdentityResponseWrapper: Codable {
    let MediaContainer: PlexServerInfo?
}
