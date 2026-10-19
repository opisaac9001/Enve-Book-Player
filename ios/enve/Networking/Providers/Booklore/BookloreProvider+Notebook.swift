import Foundation
import Logging

extension BookloreProvider {
    func fetchNotebookEntries(for book: Book) async throws -> [AppNotebookEntry] {
        guard !useLegacyRestAPI, !useKomgaFallback else { return [] }

        var entries: [AppNotebookEntry] = []
        var pageIndex = 0
        while true {
            let request = try makeRequest(
                path: "/api/v1/app/notebook/books/\(grimmoryNumericId(book))/entries",
                queryItems: [
                    URLQueryItem(name: "page", value: String(pageIndex)),
                    URLQueryItem(name: "size", value: "200"),
                ]
            )
            let (data, response) = try await performAuthorizedRequest(request)
            guard response.statusCode == 200 else { return entries }
            let page = try JSONDecoder().decode(NotebookEntriesPage.self, from: data)
            entries.append(contentsOf: page.content)
            guard page.hasNext == true else { break }
            pageIndex += 1
        }
        return entries
    }

    func fetchRemoteAnnotations(for book: Book) async throws -> [RemoteAnnotationRecord] {
        guard !useLegacyRestAPI, !useKomgaFallback else { return [] }

        let request = try makeRequest(path: "/api/v1/annotations/book/\(grimmoryNumericId(book))")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else { return [] }
        return try JSONDecoder().decode([RemoteAnnotationRecord].self, from: data)
    }

    func fetchRemoteBookmarks(for book: Book) async throws -> [RemoteBookmarkRecord] {
        guard !useLegacyRestAPI, !useKomgaFallback else { return [] }

        let request = try makeRequest(path: "/api/v1/bookmarks/book/\(grimmoryNumericId(book))")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else { return [] }
        return try JSONDecoder().decode([RemoteBookmarkRecord].self, from: data)
    }

    func createRemoteBookmark(
        for book: Book,
        title: String?,
        note: String?,
        locator: String?,
        color: String? = nil,
        priority: Int? = nil,
        positionMs: Int? = nil,
        trackIndex: Int? = nil
    ) async throws -> RemoteBookmarkRecord {
        guard !useLegacyRestAPI, !useKomgaFallback else {
            throw ProviderError.notImplemented
        }

        struct BookmarkCreateRequest: Encodable {
            let bookId: Int
            let title: String?
            let cfi: String?
            let positionMs: Int?
            let trackIndex: Int?
        }

        var request = try makeRequest(path: "/api/v1/bookmarks", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            BookmarkCreateRequest(
                bookId: Int(grimmoryNumericId(book)) ?? 0,
                title: title,
                cfi: EpubLocationBridge.epubCFIForProviderUpload(from: locator),
                positionMs: positionMs,
                trackIndex: trackIndex
            )
        )
        let (data, response) = try await performAuthorizedRequest(request)
        guard (200...201).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to create Grimmory bookmark (HTTP \(response.statusCode))")
        }
        let created = try JSONDecoder().decode(RemoteBookmarkRecord.self, from: data)

        guard note != nil || color != nil || priority != nil else { return created }

        struct BookmarkUpdateRequest: Encodable {
            let notes: String?
            let color: String?
            let priority: Int?
        }

        var updateRequest = try makeRequest(path: "/api/v1/bookmarks/\(created.id)", method: "PUT")
        updateRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        updateRequest.httpBody = try JSONEncoder().encode(
            BookmarkUpdateRequest(notes: note, color: color, priority: priority)
        )
        let (updateData, updateResponse) = try await performAuthorizedRequest(updateRequest)
        guard updateResponse.statusCode == 200 else {

            AppLogger.network.warning(
                "[Booklore] Bookmark \(created.id) created but note/color/priority update returned HTTP \(updateResponse.statusCode)"
            )
            return created
        }
        return try JSONDecoder().decode(RemoteBookmarkRecord.self, from: updateData)
    }

    func deleteRemoteBookmark(id: Int) async throws {
        guard !useLegacyRestAPI, !useKomgaFallback else { return }
        let request = try makeRequest(path: "/api/v1/bookmarks/\(id)", method: "DELETE")
        let (_, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 204 || response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to delete Grimmory bookmark (HTTP \(response.statusCode))")
        }
    }

    func createRemoteAnnotation(for book: Book, annotation: ReaderAnnotation) async throws -> RemoteAnnotationRecord {
        guard !useLegacyRestAPI, !useKomgaFallback else {
            throw ProviderError.notImplemented
        }

        struct AnnotationCreateRequest: Encodable {
            let bookId: Int
            let cfi: String?
            let text: String
            let color: String
            let style: String
            let note: String?
            let chapterTitle: String?
        }

        guard let cfi = EpubLocationBridge.epubCFIForProviderUpload(from: annotation.locator) else {
            throw ProviderError.noCFI
        }

        var request = try makeRequest(path: "/api/v1/annotations", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            AnnotationCreateRequest(
                bookId: Int(grimmoryNumericId(book)) ?? 0,
                cfi: cfi,
                text: annotation.text,
                color: annotation.colorHex,
                style: annotation.style.rawValue,
                note: annotation.note,
                chapterTitle: annotation.chapterTitle
            )
        )

        let (data, response) = try await performAuthorizedRequest(request)
        guard (200...201).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to create Grimmory annotation (HTTP \(response.statusCode))")
        }
        return try JSONDecoder().decode(RemoteAnnotationRecord.self, from: data)
    }

    func updateRemoteAnnotation(id: Int, annotation: ReaderAnnotation) async throws -> RemoteAnnotationRecord {
        guard !useLegacyRestAPI, !useKomgaFallback else {
            throw ProviderError.notImplemented
        }

        struct AnnotationUpdateRequest: Encodable {
            let color: String
            let style: String
            let note: String?
        }

        var request = try makeRequest(path: "/api/v1/annotations/\(id)", method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            AnnotationUpdateRequest(
                color: annotation.colorHex,
                style: annotation.style.rawValue,
                note: annotation.note
            )
        )

        let (data, response) = try await performAuthorizedRequest(request)
        guard (200...201).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to update Grimmory annotation (HTTP \(response.statusCode))")
        }
        return try JSONDecoder().decode(RemoteAnnotationRecord.self, from: data)
    }

    func deleteRemoteAnnotation(id: Int) async throws {
        guard !useLegacyRestAPI, !useKomgaFallback else { return }
        let request = try makeRequest(path: "/api/v1/annotations/\(id)", method: "DELETE")
        let (_, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 204 || response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to delete Grimmory annotation (HTTP \(response.statusCode))")
        }
    }

    func createBookNote(
        for book: Book,
        cfi: String?,
        selectedText: String,
        noteContent: String,
        color: String = "#00FF00",
        chapterTitle: String? = nil
    ) async throws -> RemoteBookNoteRecord {
        guard !useLegacyRestAPI, !useKomgaFallback else {
            throw ProviderError.notImplemented
        }

        struct BookNoteCreateRequest: Encodable {
            let bookId: Int
            let cfi: String?
            let selectedText: String
            let noteContent: String
            let color: String
            let chapterTitle: String?
        }

        var request = try makeRequest(path: "/api/v2/book-notes", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            BookNoteCreateRequest(
                bookId: Int(grimmoryNumericId(book)) ?? 0,
                cfi: cfi,
                selectedText: selectedText,
                noteContent: noteContent,
                color: color,
                chapterTitle: chapterTitle
            )
        )

        let (data, response) = try await performAuthorizedRequest(request)
        guard (200...201).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to create Grimmory book note (HTTP \(response.statusCode))")
        }
        return try JSONDecoder().decode(RemoteBookNoteRecord.self, from: data)
    }

    func fetchBookNotes(for book: Book) async throws -> [RemoteBookNoteRecord] {
        guard !useLegacyRestAPI, !useKomgaFallback else { return [] }

        let request = try makeRequest(path: "/api/v2/book-notes/book/\(grimmoryNumericId(book))")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch Grimmory book notes (HTTP \(response.statusCode))")
        }
        return try JSONDecoder().decode([RemoteBookNoteRecord].self, from: data)
    }

    func updateBookNote(id: Int, annotation: ReaderAnnotation) async throws -> RemoteBookNoteRecord {
        guard !useLegacyRestAPI, !useKomgaFallback else {
            throw ProviderError.notImplemented
        }

        struct BookNoteUpdateRequest: Encodable {
            let noteContent: String?
            let color: String?
            let chapterTitle: String?
        }

        var request = try makeRequest(path: "/api/v2/book-notes/\(id)", method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            BookNoteUpdateRequest(
                noteContent: annotation.note,
                color: annotation.colorHex.wholeMatch(of: /#[0-9A-Fa-f]{6}/) == nil ? nil : annotation.colorHex,
                chapterTitle: annotation.chapterTitle
            )
        )

        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to update Grimmory book note (HTTP \(response.statusCode))")
        }
        return try JSONDecoder().decode(RemoteBookNoteRecord.self, from: data)
    }

    func deleteBookNote(id: Int) async throws {
        guard !useLegacyRestAPI, !useKomgaFallback else { return }
        let request = try makeRequest(path: "/api/v2/book-notes/\(id)", method: "DELETE")
        let (_, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 204 || response.statusCode == 200 || response.statusCode == 404 else {
            throw ProviderError.serverError("Failed to delete Grimmory book note (HTTP \(response.statusCode))")
        }
    }
}
