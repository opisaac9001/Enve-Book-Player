import Foundation

enum ReaderNotebookMerge {
    struct Snapshot: Equatable {
        var bookmarks: [Bookmark]
        var annotations: [ReaderAnnotation]
    }

    static func applyingBookloreRecords(
        annotations remoteAnnotations: [BookloreProvider.RemoteAnnotationRecord],
        bookmarks remoteBookmarks: [BookloreProvider.RemoteBookmarkRecord],
        to snapshot: Snapshot,
        bookID: String,
        bookStableID: String
    ) -> Snapshot {
        var mergedAnnotations = snapshot.annotations
        var mergedBookmarks = snapshot.bookmarks

        for record in remoteAnnotations {
            if let idx = mergedAnnotations.firstIndex(where: { $0.remoteID == record.id }) {
                let remoteDate = providerDate(record.updatedAt) ?? providerDate(record.createdAt) ?? Date()
                if remoteDate > mergedAnnotations[idx].updatedAt {
                    let resolvedLocator: String?
                    if let serverCFI = record.cfi, !serverCFI.isEmpty {
                        resolvedLocator = locatorJSON(fromCFI: serverCFI, existingLocator: mergedAnnotations[idx].locator)
                    } else {
                        resolvedLocator = mergedAnnotations[idx].locator
                    }

                    mergedAnnotations[idx] = ReaderAnnotation(
                        id: mergedAnnotations[idx].id,
                        bookId: bookID,
                        locator: resolvedLocator,
                        position: mergedAnnotations[idx].position,
                        text: record.text ?? mergedAnnotations[idx].text,
                        note: record.note,
                        colorHex: record.color ?? mergedAnnotations[idx].colorHex,
                        style: ReaderAnnotationStyle(rawValue: record.style ?? "highlight") ?? .highlight,
                        chapterTitle: record.chapterTitle ?? mergedAnnotations[idx].chapterTitle,
                        createdAt: mergedAnnotations[idx].createdAt,
                        updatedAt: remoteDate,
                        remoteID: record.id,
                        isRemotePlaceholder: resolvedLocator == nil
                    )
                } else if mergedAnnotations[idx].isRemotePlaceholder, let serverCFI = record.cfi, !serverCFI.isEmpty {
                    mergedAnnotations[idx] = ReaderAnnotation(
                        id: mergedAnnotations[idx].id,
                        bookId: bookID,
                        locator: locatorJSON(fromCFI: serverCFI, existingLocator: nil),
                        position: mergedAnnotations[idx].position,
                        text: mergedAnnotations[idx].text,
                        note: mergedAnnotations[idx].note,
                        colorHex: mergedAnnotations[idx].colorHex,
                        style: mergedAnnotations[idx].style,
                        chapterTitle: mergedAnnotations[idx].chapterTitle ?? record.chapterTitle,
                        createdAt: mergedAnnotations[idx].createdAt,
                        updatedAt: mergedAnnotations[idx].updatedAt,
                        remoteID: record.id,
                        isRemotePlaceholder: false
                    )
                }
            } else {
                let locator: String?
                if let cfi = record.cfi, !cfi.isEmpty {
                    locator = locatorJSON(fromCFI: cfi, existingLocator: nil)
                } else {
                    locator = nil
                }

                mergedAnnotations.append(
                    ReaderAnnotation(
                        bookId: bookID,
                        locator: locator,
                        position: 0,
                        text: record.text ?? "Synced annotation",
                        note: record.note,
                        colorHex: record.color ?? "#FFF59D",
                        style: ReaderAnnotationStyle(rawValue: record.style ?? "highlight") ?? .highlight,
                        chapterTitle: record.chapterTitle,
                        createdAt: providerDate(record.createdAt) ?? Date(),
                        updatedAt: providerDate(record.updatedAt) ?? providerDate(record.createdAt) ?? Date(),
                        remoteID: record.id,
                        isRemotePlaceholder: locator == nil
                    )
                )
            }
        }

        for record in remoteBookmarks {
            if mergedBookmarks.contains(where: { $0.remoteID == record.id }) { continue }

            let locator: String?
            if let cfi = record.cfi, !cfi.isEmpty {
                locator = locatorJSON(fromCFI: cfi, existingLocator: nil)
            } else {
                locator = nil
            }

            let mediaType: AppMediaType = record.positionMs != nil ? .audiobook : .ebook
            let position: TimeInterval = record.positionMs.map { $0 / 1000.0 } ?? 0

            mergedBookmarks.append(
                Bookmark(
                    bookId: bookStableID,
                    position: position,
                    title: record.title ?? "Synced Bookmark",
                    note: record.notes,
                    timestamp: providerDate(record.updatedAt) ?? providerDate(record.createdAt) ?? Date(),
                    locator: locator,
                    mediaType: mediaType,
                    chapterTitle: nil,
                    remoteID: record.id,
                    isRemotePlaceholder: locator == nil && record.positionMs == nil
                )
            )
        }

        return Snapshot(bookmarks: mergedBookmarks, annotations: mergedAnnotations)
    }

    static func applyingBookloreNotebookEntries(
        _ entries: [BookloreProvider.AppNotebookEntry],
        to snapshot: Snapshot,
        bookID: String,
        bookStableID: String
    ) -> Snapshot {
        var mergedBookmarks = snapshot.bookmarks
        var mergedAnnotations = snapshot.annotations

        for entry in entries {
            switch entry.type {
            case .bookmark:
                if mergedBookmarks.contains(where: { $0.remoteID == entry.id }) { continue }
                mergedBookmarks.append(
                    Bookmark(
                        bookId: bookStableID,
                        position: 0,
                        title: entry.text ?? "Synced Bookmark",
                        note: entry.note,
                        timestamp: providerDate(entry.updatedAt) ?? providerDate(entry.createdAt) ?? Date(),
                        locator: nil,
                        mediaType: .ebook,
                        chapterTitle: nil,
                        remoteID: entry.id,
                        isRemotePlaceholder: true
                    )
                )
            case .note:
                // Note ids belong to the book-notes table; those merge through applyingGrimmoryBookNotes.
                continue
            case .highlight:
                if mergedAnnotations.contains(where: { $0.remoteID == entry.id }) { continue }
                mergedAnnotations.append(
                    ReaderAnnotation(
                        bookId: bookID,
                        locator: nil,
                        position: 0,
                        text: entry.text ?? "Synced annotation",
                        note: entry.note,
                        colorHex: entry.color ?? "#FFF59D",
                        style: ReaderAnnotationStyle(rawValue: entry.style ?? "highlight") ?? .highlight,
                        chapterTitle: nil,
                        createdAt: providerDate(entry.createdAt) ?? Date(),
                        updatedAt: providerDate(entry.updatedAt) ?? providerDate(entry.createdAt) ?? Date(),
                        remoteID: entry.id,
                        isRemotePlaceholder: true
                    )
                )
            }
        }

        return Snapshot(bookmarks: mergedBookmarks, annotations: mergedAnnotations)
    }

    // `records` must be the complete server listing: a mapped artifact missing from it was deleted remotely.
    @MainActor
    static func applyingSiloRecords(
        _ records: [SiloReaderAnnotationRecord],
        to snapshot: Snapshot,
        scope: SiloReaderArtifactScope,
        idMap: any SiloReaderArtifactIDMapping
    ) -> Snapshot {
        var mergedBookmarks = snapshot.bookmarks
        var mergedAnnotations = snapshot.annotations
        let remoteIDs = Set(records.map(\.id))
        let guards = idMap.artifactGuards(in: scope)

        for record in records where guards[record.id]?.state != .pendingDelete {
            if record.kind == "bookmark" {
                mergeSiloBookmark(record, with: guards[record.id], into: &mergedBookmarks, idMap: idMap, scope: scope)
            } else {
                mergeSiloAnnotation(record, with: guards[record.id], into: &mergedAnnotations, idMap: idMap, scope: scope)
            }
        }

        func discardsAfterRemoteDeletion(_ remoteID: String, localDate: Date) -> Bool {
            if let current = guards[remoteID], current.state != .synced || localDate > current.recordedAt {
                idMap.setArtifactGuard(.init(etag: current.etag, state: .conflict, recordedAt: current.recordedAt), remoteID: remoteID, in: scope)
                return false
            }
            idMap.setArtifactGuard(nil, remoteID: remoteID, in: scope)
            return true
        }
        mergedAnnotations.removeAll { annotation in
            guard let remoteID = idMap.annotationRemoteID(connectionID: scope.connectionID, bookID: scope.bookID, localID: annotation.id),
                !remoteIDs.contains(remoteID), discardsAfterRemoteDeletion(remoteID, localDate: annotation.updatedAt)
            else { return false }
            idMap.removeAnnotationRemoteID(connectionID: scope.connectionID, bookID: scope.bookID, localID: annotation.id)
            return true
        }
        mergedBookmarks.removeAll { bookmark in
            guard let remoteID = idMap.bookmarkRemoteID(connectionID: scope.connectionID, bookID: scope.bookID, localID: bookmark.id),
                !remoteIDs.contains(remoteID), discardsAfterRemoteDeletion(remoteID, localDate: bookmark.timestamp)
            else { return false }
            idMap.removeBookmarkRemoteID(connectionID: scope.connectionID, bookID: scope.bookID, localID: bookmark.id)
            return true
        }
        for (remoteID, artifactGuard) in guards where artifactGuard.state == .pendingDelete && !remoteIDs.contains(remoteID) {
            idMap.setArtifactGuard(nil, remoteID: remoteID, in: scope)
        }

        return Snapshot(bookmarks: mergedBookmarks, annotations: mergedAnnotations)
    }

    @MainActor
    private static func adoptsSiloRecord(
        _ record: SiloReaderAnnotationRecord,
        with artifactGuard: SiloReaderArtifactGuard?,
        localDate: Date,
        idMap: any SiloReaderArtifactIDMapping,
        scope: SiloReaderArtifactScope
    ) -> Bool {
        let remoteDate = record.updatedAt ?? record.createdAt ?? .distantPast
        guard let artifactGuard else {
            idMap.setArtifactGuard(SiloReaderArtifactGuard(etag: record.etag, state: .synced, recordedAt: Date()), remoteID: record.id, in: scope)
            return remoteDate > localDate
        }
        switch artifactGuard.state {
        case .synced:
            if localDate > artifactGuard.recordedAt {
                idMap.setArtifactGuard(.init(etag: artifactGuard.etag, state: .pendingUpdate, recordedAt: localDate), remoteID: record.id, in: scope)
                return false
            }
            guard artifactGuard.etag != record.etag else { return false }
            idMap.setArtifactGuard(SiloReaderArtifactGuard(etag: record.etag, state: .synced, recordedAt: Date()), remoteID: record.id, in: scope)
            return true
        case .pendingUpdate where artifactGuard.etag.isEmpty:
            let state: SiloReaderArtifactGuard.State = .conflict
            idMap.setArtifactGuard(
                SiloReaderArtifactGuard(etag: record.etag, state: state, recordedAt: artifactGuard.recordedAt),
                remoteID: record.id,
                in: scope
            )
            return false
        case .pendingUpdate, .pendingDelete, .conflict:
            return false
        }
    }

    @MainActor
    static func applyingGrimmoryBookNotes(
        _ records: [BookloreProvider.RemoteBookNoteRecord],
        to snapshot: Snapshot,
        bookID: String,
        bookStableID: String,
        connectionID: UUID,
        idMap: any GrimmoryBookNoteIDMapping
    ) -> Snapshot {
        var mergedAnnotations = snapshot.annotations

        for record in records {
            let remoteDate = providerDate(record.updatedAt) ?? providerDate(record.createdAt) ?? Date()
            let note = record.noteContent.flatMap { $0.isEmpty ? nil : $0 }
            let mappedLocalID = idMap.localID(connectionID: connectionID, bookID: bookStableID, noteID: record.id)
            if let mappedLocalID, let index = mergedAnnotations.firstIndex(where: { $0.id == mappedLocalID }) {
                guard remoteDate > mergedAnnotations[index].updatedAt else { continue }
                let existing = mergedAnnotations[index]
                let locator = locatorJSON(fromCFI: record.cfi, existingLocator: existing.locator)
                mergedAnnotations[index] = ReaderAnnotation(
                    id: existing.id,
                    bookId: existing.bookId,
                    locator: locator,
                    position: existing.position,
                    text: record.selectedText.flatMap { $0.isEmpty ? nil : $0 } ?? existing.text,
                    note: note,
                    colorHex: record.color ?? existing.colorHex,
                    style: existing.style,
                    chapterTitle: record.chapterTitle ?? existing.chapterTitle,
                    createdAt: existing.createdAt,
                    updatedAt: remoteDate,
                    remoteID: existing.remoteID,
                    isRemotePlaceholder: locator == nil
                )
                continue
            }

            if let mappedLocalID {
                idMap.removeNoteID(connectionID: connectionID, bookID: bookStableID, localID: mappedLocalID)
            }
            let locator = locatorJSON(fromCFI: record.cfi, existingLocator: nil)
            let annotation = ReaderAnnotation(
                bookId: bookID,
                locator: locator,
                text: record.selectedText.flatMap { $0.isEmpty ? nil : $0 } ?? note ?? "Synced note",
                note: note,
                colorHex: record.color ?? "#FFF59D",
                chapterTitle: record.chapterTitle,
                createdAt: providerDate(record.createdAt) ?? Date(),
                updatedAt: remoteDate,
                isRemotePlaceholder: locator == nil
            )
            idMap.setNoteID(record.id, connectionID: connectionID, bookID: bookStableID, localID: annotation.id)
            mergedAnnotations.append(annotation)
        }

        let remoteIDs = Set(records.map(\.id))
        mergedAnnotations.removeAll { annotation in
            guard let noteID = idMap.noteID(connectionID: connectionID, bookID: bookStableID, localID: annotation.id),
                !remoteIDs.contains(noteID)
            else { return false }
            idMap.removeNoteID(connectionID: connectionID, bookID: bookStableID, localID: annotation.id)
            return true
        }

        return Snapshot(bookmarks: snapshot.bookmarks, annotations: mergedAnnotations)
    }

    static func providerDate(_ rawValue: String?) -> Date? {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        return ISO8601Timestamp.parse(rawValue) ?? DateFormatter.bookloreFallback.date(from: rawValue)
    }

    static func locatorJSON(fromCFI cfi: String?, existingLocator: String?) -> String? {
        guard let cfi, !cfi.isEmpty else { return existingLocator }

        if let existing = existingLocator,
            let data = existing.data(using: .utf8),
            var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            var locations = json["locations"] as? [String: Any] ?? [:]
            locations["cfi"] = cfi
            if locations[EpubLocationBridge.sourceEngineLocationKey] == nil {
                locations[EpubLocationBridge.sourceEngineLocationKey] = ReaderEngineKind.foliate.rawValue
            }
            json["locations"] = locations
            if let newData = try? JSONSerialization.data(withJSONObject: json),
                let newStr = String(data: newData, encoding: .utf8)
            {
                return newStr
            }
        }

        let locator: [String: Any] = [
            "href": "",
            "type": "application/xhtml+xml",
            "locations": [
                "cfi": cfi,
                EpubLocationBridge.sourceEngineLocationKey: ReaderEngineKind.foliate.rawValue,
            ],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: locator),
            let str = String(data: data, encoding: .utf8)
        {
            return str
        }
        return existingLocator
    }

    static func siloReadiumLocator(_ record: SiloReaderAnnotationRecord) -> String? {
        if let cfi = siloCFI(record) {
            return locatorJSON(fromCFI: cfi, existingLocator: nil)
        }
        if let location = record.location?.trimmingCharacters(in: .whitespacesAndNewlines), location.hasPrefix("{") {
            return location
        }
        return nil
    }

    static func siloCFI(_ record: SiloReaderAnnotationRecord) -> String? {
        if let cfi = record.cfiRange?.trimmingCharacters(in: .whitespacesAndNewlines), cfi.hasPrefix("epubcfi(") {
            return cfi
        }
        return siloCFI(fromLocator: record.location)
    }

    static func siloCFI(fromLocator locator: String?) -> String? {
        guard let locator = locator?.trimmingCharacters(in: .whitespacesAndNewlines), !locator.isEmpty else {
            return nil
        }
        if locator.hasPrefix("epubcfi(") {
            return locator
        }
        guard let data = locator.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let locations = json["locations"] as? [String: Any]
        else {
            return nil
        }
        if let fragments = locations["fragments"] as? [String],
            let cfi = fragments.first(where: { $0.hasPrefix("epubcfi(") })
        {
            return cfi
        }
        if let cfi = locations["cfi"] as? String, cfi.hasPrefix("epubcfi(") {
            return cfi
        }
        return nil
    }

    static func siloPosition(_ record: SiloReaderAnnotationRecord, fallback: Double) -> Double {
        if let value = record.metadata["enve_position"].flatMap(Double.init) {
            return value
        }
        if let location = record.location?.trimmingCharacters(in: .whitespacesAndNewlines),
            location.hasPrefix("fraction:"),
            let value = Double(location.dropFirst("fraction:".count))
        {
            return value
        }
        if let locator = siloReadiumLocator(record),
            let data = locator.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let locations = json["locations"] as? [String: Any]
        {
            if let value = locations["totalProgression"] as? Double {
                return value
            }
            if let value = locations["progression"] as? Double {
                return value
            }
        }
        return fallback
    }

    @MainActor
    private static func mergeSiloAnnotation(
        _ record: SiloReaderAnnotationRecord,
        with artifactGuard: SiloReaderArtifactGuard?,
        into local: inout [ReaderAnnotation],
        idMap: any SiloReaderArtifactIDMapping,
        scope: SiloReaderArtifactScope
    ) {
        let connectionID = scope.connectionID
        let bookStableID = scope.bookID
        let remoteDate = record.updatedAt ?? record.createdAt ?? Date()
        let mappedLocalID =
            idMap.localAnnotationID(connectionID: connectionID, bookID: bookStableID, remoteID: record.id)
            ?? record.metadata["enve_local_id"]
        let remoteCFI = siloCFI(record)
        let index =
            mappedLocalID.flatMap { localID in local.firstIndex(where: { $0.id == localID }) }
            ?? remoteCFI.flatMap { cfi in
                local.firstIndex(where: {
                    idMap.annotationRemoteID(connectionID: connectionID, bookID: bookStableID, localID: $0.id) == nil
                        && siloCFI(fromLocator: $0.locator) == cfi
                })
            }

        if let index {
            idMap.setAnnotationRemoteID(record.id, connectionID: connectionID, bookID: bookStableID, localID: local[index].id)
            guard adoptsSiloRecord(record, with: artifactGuard, localDate: local[index].updatedAt, idMap: idMap, scope: scope)
            else { return }
            local[index] = ReaderAnnotation(
                id: local[index].id,
                bookId: bookStableID,
                locator: siloReadiumLocator(record) ?? local[index].locator,
                position: siloPosition(record, fallback: local[index].position),
                text: record.selectedText.isEmpty ? local[index].text : record.selectedText,
                note: record.note.isEmpty ? nil : record.note,
                colorHex: record.color.isEmpty ? local[index].colorHex : record.color,
                style: ReaderAnnotationStyle(rawValue: record.style) ?? local[index].style,
                chapterTitle: record.metadata["enve_chapter_title"].flatMap { $0.isEmpty ? nil : $0 } ?? local[index].chapterTitle,
                createdAt: local[index].createdAt,
                updatedAt: remoteDate,
                remoteID: local[index].remoteID,
                isRemotePlaceholder: siloReadiumLocator(record) == nil
            )
            return
        }

        let localID = mappedLocalID?.isEmpty == false ? mappedLocalID! : UUID().uuidString
        idMap.setAnnotationRemoteID(record.id, connectionID: connectionID, bookID: bookStableID, localID: localID)
        idMap.setArtifactGuard(SiloReaderArtifactGuard(etag: record.etag, state: .synced, recordedAt: Date()), remoteID: record.id, in: scope)
        local.append(
            ReaderAnnotation(
                id: localID,
                bookId: bookStableID,
                locator: siloReadiumLocator(record),
                position: siloPosition(record, fallback: 0),
                text: record.selectedText,
                note: record.note.isEmpty ? nil : record.note,
                colorHex: record.color.isEmpty ? "#facc15" : record.color,
                style: ReaderAnnotationStyle(rawValue: record.style) ?? .highlight,
                chapterTitle: record.metadata["enve_chapter_title"].flatMap { $0.isEmpty ? nil : $0 },
                createdAt: record.createdAt ?? Date(),
                updatedAt: remoteDate,
                isRemotePlaceholder: siloReadiumLocator(record) == nil
            )
        )
    }

    @MainActor
    private static func mergeSiloBookmark(
        _ record: SiloReaderAnnotationRecord,
        with artifactGuard: SiloReaderArtifactGuard?,
        into local: inout [Bookmark],
        idMap: any SiloReaderArtifactIDMapping,
        scope: SiloReaderArtifactScope
    ) {
        let connectionID = scope.connectionID
        let bookStableID = scope.bookID
        let remoteDate = record.updatedAt ?? record.createdAt ?? Date()
        let mappedLocalID =
            idMap.localBookmarkID(connectionID: connectionID, bookID: bookStableID, remoteID: record.id)
            ?? record.metadata["enve_local_id"]
        let index = mappedLocalID.flatMap { localID in local.firstIndex(where: { $0.id == localID }) }
        let locator = siloReadiumLocator(record)

        if let index {
            idMap.setBookmarkRemoteID(record.id, connectionID: connectionID, bookID: bookStableID, localID: local[index].id)
            guard adoptsSiloRecord(record, with: artifactGuard, localDate: local[index].timestamp, idMap: idMap, scope: scope)
            else { return }
            local[index] = Bookmark(
                id: local[index].id,
                bookId: bookStableID,
                position: siloPosition(record, fallback: local[index].position),
                title: record.selectedText.isEmpty ? local[index].title : record.selectedText,
                note: record.note.isEmpty ? nil : record.note,
                timestamp: remoteDate,
                locator: locator ?? local[index].locator,
                mediaType: .ebook,
                chapterTitle: record.metadata["enve_chapter_title"].flatMap { $0.isEmpty ? nil : $0 } ?? local[index].chapterTitle,
                remoteID: local[index].remoteID,
                isRemotePlaceholder: locator == nil
            )
            return
        }

        let localID = mappedLocalID?.isEmpty == false ? mappedLocalID! : UUID().uuidString
        idMap.setBookmarkRemoteID(record.id, connectionID: connectionID, bookID: bookStableID, localID: localID)
        idMap.setArtifactGuard(SiloReaderArtifactGuard(etag: record.etag, state: .synced, recordedAt: Date()), remoteID: record.id, in: scope)
        local.append(
            Bookmark(
                id: localID,
                bookId: bookStableID,
                position: siloPosition(record, fallback: 0),
                title: record.selectedText.isEmpty ? "Synced Bookmark" : record.selectedText,
                note: record.note.isEmpty ? nil : record.note,
                timestamp: remoteDate,
                locator: locator,
                mediaType: .ebook,
                chapterTitle: record.metadata["enve_chapter_title"].flatMap { $0.isEmpty ? nil : $0 },
                isRemotePlaceholder: locator == nil
            )
        )
    }
}
