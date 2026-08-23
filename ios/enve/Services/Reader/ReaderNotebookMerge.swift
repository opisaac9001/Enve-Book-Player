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
            case .highlight, .note:
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

    @MainActor
    static func applyingSiloRecords(
        _ records: [SiloReaderAnnotationRecord],
        to snapshot: Snapshot,
        bookStableID: String,
        connectionID: UUID,
        idMap: any SiloReaderArtifactIDMapping
    ) -> Snapshot {
        var mergedBookmarks = snapshot.bookmarks
        var mergedAnnotations = snapshot.annotations
        let remoteIDs = Set(records.map(\.id))

        for record in records {
            if record.kind == "bookmark" {
                mergeSiloBookmark(
                    record,
                    into: &mergedBookmarks,
                    idMap: idMap,
                    connectionID: connectionID,
                    bookStableID: bookStableID
                )
            } else {
                mergeSiloAnnotation(
                    record,
                    into: &mergedAnnotations,
                    idMap: idMap,
                    connectionID: connectionID,
                    bookStableID: bookStableID
                )
            }
        }

        mergedAnnotations.removeAll { annotation in
            guard let remoteID = idMap.annotationRemoteID(connectionID: connectionID, bookID: bookStableID, localID: annotation.id) else {
                return false
            }
            return !remoteIDs.contains(remoteID)
        }
        mergedBookmarks.removeAll { bookmark in
            guard let remoteID = idMap.bookmarkRemoteID(connectionID: connectionID, bookID: bookStableID, localID: bookmark.id) else {
                return false
            }
            return !remoteIDs.contains(remoteID)
        }

        return Snapshot(bookmarks: mergedBookmarks, annotations: mergedAnnotations)
    }

    static func providerDate(_ rawValue: String?) -> Date? {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let precise = formatter.date(from: rawValue) {
            return precise
        }
        return ISO8601DateFormatter().date(from: rawValue)
            ?? DateFormatter.bookloreFallback.date(from: rawValue)
    }

    static func locatorJSON(fromCFI cfi: String?, existingLocator: String?) -> String? {
        guard let cfi, !cfi.isEmpty else { return existingLocator }

        if let existing = existingLocator,
            let data = existing.data(using: .utf8),
            var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            var locations = json["locations"] as? [String: Any] ?? [:]
            locations["cfi"] = cfi
            locations[EpubLocationBridge.sourceEngineLocationKey] = ReaderEngineKind.foliate.rawValue
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
        into local: inout [ReaderAnnotation],
        idMap: any SiloReaderArtifactIDMapping,
        connectionID: UUID,
        bookStableID: String
    ) {
        let remoteDate = record.updatedAt ?? record.createdAt ?? Date()
        let mappedLocalID =
            idMap.localAnnotationID(connectionID: connectionID, bookID: bookStableID, remoteID: record.id)
            ?? record.metadata["enve_local_id"]
        let remoteCFI = siloCFI(record)
        let index =
            mappedLocalID.flatMap { localID in local.firstIndex(where: { $0.id == localID }) }
            ?? remoteCFI.flatMap { cfi in local.firstIndex(where: { siloCFI(fromLocator: $0.locator) == cfi }) }

        if let index {
            idMap.setAnnotationRemoteID(record.id, connectionID: connectionID, bookID: bookStableID, localID: local[index].id)
            guard remoteDate > local[index].updatedAt else { return }
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
        into local: inout [Bookmark],
        idMap: any SiloReaderArtifactIDMapping,
        connectionID: UUID,
        bookStableID: String
    ) {
        let remoteDate = record.updatedAt ?? record.createdAt ?? Date()
        let mappedLocalID =
            idMap.localBookmarkID(connectionID: connectionID, bookID: bookStableID, remoteID: record.id)
            ?? record.metadata["enve_local_id"]
        let index = mappedLocalID.flatMap { localID in local.firstIndex(where: { $0.id == localID }) }
        let locator = siloReadiumLocator(record)

        if let index {
            idMap.setBookmarkRemoteID(record.id, connectionID: connectionID, bookID: bookStableID, localID: local[index].id)
            guard remoteDate > local[index].timestamp else { return }
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
