import Foundation
import Logging

extension BookloreProvider {
    func fetchUsers() async throws -> [GrimmoryManagedUser] {
        let request = try makeRequest(path: "/api/v1/users")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            if response.statusCode == 403 { throw ProviderError.unauthorized }
            throw ProviderError.serverError("Failed to fetch users (HTTP \(response.statusCode))")
        }
        return (try? JSONDecoder().decode([GrimmoryManagedUser].self, from: data)) ?? []
    }

    func fetchUser(id: Int) async throws -> GrimmoryManagedUser {
        let request = try makeRequest(path: "/api/v1/users/\(id)")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            if response.statusCode == 403 { throw ProviderError.unauthorized }
            throw ProviderError.serverError("Failed to fetch user (HTTP \(response.statusCode))")
        }
        return try JSONDecoder().decode(GrimmoryManagedUser.self, from: data)
    }

    func createUser(_ request: GrimmoryCreateUserRequest) async throws {
        let body = try JSONEncoder().encode(request)
        let req = try makeRequest(
            path: "/api/v1/auth/register",
            method: "POST",
            body: body,
            contentType: "application/json"
        )
        let (_, response) = try await performAuthorizedRequest(req)
        guard (200...204).contains(response.statusCode) else {
            if response.statusCode == 403 { throw ProviderError.unauthorized }
            throw ProviderError.serverError("Failed to create user (HTTP \(response.statusCode))")
        }
    }

    func updateUser(id: Int, request: GrimmoryUpdateUserRequest) async throws {
        let body = try JSONEncoder().encode(request)
        let req = try makeRequest(
            path: "/api/v1/users/\(id)",
            method: "PUT",
            body: body,
            contentType: "application/json"
        )
        let (_, response) = try await performAuthorizedRequest(req)
        guard (200...204).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to update user (HTTP \(response.statusCode))")
        }
    }

    func deleteUser(id: Int) async throws {
        let req = try makeRequest(path: "/api/v1/users/\(id)", method: "DELETE")
        let (_, response) = try await performAuthorizedRequest(req)
        guard (200...204).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to delete user (HTTP \(response.statusCode))")
        }
    }

    func changeUserPassword(userId: Int, newPassword: String) async throws {
        struct Req: Encodable { let userId: Int; let newPassword: String }
        let body = try JSONEncoder().encode(Req(userId: userId, newPassword: newPassword))
        let req = try makeRequest(
            path: "/api/v1/users/change-user-password",
            method: "PUT",
            body: body,
            contentType: "application/json"
        )
        let (_, response) = try await performAuthorizedRequest(req)
        guard (200...204).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to change password (HTTP \(response.statusCode))")
        }
    }

    func createShelf(name: String, icon: String? = nil, isPublic: Bool = false) async throws -> GrimmoryShelf {
        struct Req: Encodable { let name: String; let icon: String?; let publicShelf: Bool }
        let body = try JSONEncoder().encode(Req(name: name, icon: icon, publicShelf: isPublic))
        let req = try makeRequest(
            path: "/api/v1/shelves",
            method: "POST",
            body: body,
            contentType: "application/json"
        )
        let (data, response) = try await performAuthorizedRequest(req)
        guard (200...201).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to create shelf (HTTP \(response.statusCode))")
        }
        return try JSONDecoder().decode(GrimmoryShelf.self, from: data)
    }

    func updateShelf(id: Int, name: String, icon: String? = nil, isPublic: Bool = false) async throws {
        struct Req: Encodable { let name: String; let icon: String?; let publicShelf: Bool }
        let body = try JSONEncoder().encode(Req(name: name, icon: icon, publicShelf: isPublic))
        let req = try makeRequest(
            path: "/api/v1/shelves/\(id)",
            method: "PUT",
            body: body,
            contentType: "application/json"
        )
        let (_, response) = try await performAuthorizedRequest(req)
        guard (200...204).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to update shelf (HTTP \(response.statusCode))")
        }
    }

    func deleteShelf(id: Int) async throws {
        let req = try makeRequest(path: "/api/v1/shelves/\(id)", method: "DELETE")
        let (_, response) = try await performAuthorizedRequest(req)
        guard (200...204).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to delete shelf (HTTP \(response.statusCode))")
        }
    }

    func fetchMagicShelves() async throws -> [GrimmoryMagicShelf] {
        let request = try makeRequest(path: "/api/magic-shelves")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else { return [] }
        return (try? JSONDecoder().decode([GrimmoryMagicShelf].self, from: data)) ?? []
    }

    func saveMagicShelf(_ shelf: GrimmoryMagicShelf) async throws -> GrimmoryMagicShelf {
        let body = try JSONEncoder().encode(shelf)
        let req = try makeRequest(
            path: "/api/magic-shelves",
            method: "POST",
            body: body,
            contentType: "application/json"
        )
        let (data, response) = try await performAuthorizedRequest(req)
        guard (200...201).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to save magic shelf (HTTP \(response.statusCode))")
        }
        return try JSONDecoder().decode(GrimmoryMagicShelf.self, from: data)
    }

    func deleteMagicShelf(id: Int) async throws {
        let req = try makeRequest(path: "/api/magic-shelves/\(id)", method: "DELETE")
        let (_, response) = try await performAuthorizedRequest(req)
        guard (200...204).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to delete magic shelf (HTTP \(response.statusCode))")
        }
    }
}
