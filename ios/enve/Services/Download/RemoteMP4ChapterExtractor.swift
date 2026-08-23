import Foundation
import Logging

enum RemoteMP4ChapterExtractor {
    private static let probeHeadBytes = 2 * 1024 * 1024
    private static let probeTailBytes = 8 * 1024 * 1024
    private static let probeExtendedTailBytes = 32 * 1024 * 1024
    private static let maxMoovBytes: Int64 = 128 * 1024 * 1024

    private struct Atom {
        let type: String
        let start: Int
        let headerSize: Int
        let size: Int

        var contentStart: Int { start + headerSize }
        var end: Int { start + size }
    }

    private struct RemoteAtom {
        let type: String
        let offset: Int64
        let headerSize: Int64
        let size: Int64
    }

    private struct Track {
        let id: UInt32
        let handler: String?
        let timescale: UInt32
        let sampleDurations: [UInt32]
        let sampleSizes: [UInt32]
        let sampleOffsets: [UInt64]
        let chapterReferences: [UInt32]

        var isTextTrack: Bool {
            handler == "text" || handler == "sbtl" || handler == "subt"
        }
    }

    static func extractChapters(from url: URL, headers: [String: String], durationHint: TimeInterval?) async -> [Chapter]? {
        guard isMP4Like(url) else { return nil }

        do {
            let client = RangeClient(url: url, headers: headers)
            let head = try await client.read(start: 0, length: probeHeadBytes)
            if let chapters = try await parseChapters(fromMP4Window: head.data, durationHint: durationHint, client: client),
                !chapters.isEmpty
            {
                return chapters
            }

            let totalSize: Int64?
            if let headSize = head.totalSize {
                totalSize = headSize
            } else {
                totalSize = try? await client.contentLength()
            }
            if let moov = try? await findTopLevelAtom(type: "moov", totalSize: totalSize, client: client),
                moov.size > moov.headerSize,
                moov.size <= maxMoovBytes
            {
                let moovData = try await client.read(start: moov.offset + moov.headerSize, length: Int(moov.size - moov.headerSize)).data
                if let chapters = try await parseChapters(fromMoovPayload: moovData, durationHint: durationHint, client: client),
                    !chapters.isEmpty
                {
                    return chapters
                }
            }

            if let totalSize {
                for tailLength in [probeTailBytes, probeExtendedTailBytes] where totalSize > Int64(tailLength) {
                    let start = max(totalSize - Int64(tailLength), 0)
                    let tail = try await client.read(start: start, length: tailLength)
                    if let chapters = try await parseChapters(fromMP4Window: tail.data, durationHint: durationHint, client: client),
                        !chapters.isEmpty
                    {
                        return chapters
                    }
                }
            }

            return nil
        } catch {
            AppLogger.network.debug(
                "[RemoteMP4ChapterExtractor] \(DiagnosticLogSanitizer.fileDescriptor(for: url)): \(error.localizedDescription)"
            )
            return nil
        }
    }

    private static func isMP4Like(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty || ext == "m4b" || ext == "m4a" || ext == "mp4"
    }

    private static func findTopLevelAtom(type: String, totalSize: Int64?, client: RangeClient) async throws -> RemoteAtom {
        var offset: Int64 = 0
        let limit = totalSize ?? (512 * 1024 * 1024)

        while offset + 8 <= limit {
            let header = try await client.read(start: offset, length: 16).data
            guard header.count >= 8 else { break }

            let size32 = UInt64.read(from: header, at: 0, byteCount: 4)
            let atomType = header.asciiString(at: 4, count: 4)
            let headerSize: Int64
            let size: Int64
            if size32 == 1 {
                guard header.count >= 16 else { break }
                headerSize = 16
                size = Int64(UInt64.read(from: header, at: 8, byteCount: 8))
            } else if size32 == 0 {
                guard let totalSize else { break }
                headerSize = 8
                size = totalSize - offset
            } else {
                headerSize = 8
                size = Int64(size32)
            }

            guard size >= headerSize else { break }
            if atomType == type {
                return RemoteAtom(type: atomType, offset: offset, headerSize: headerSize, size: size)
            }
            offset += size
        }

        throw NSError(domain: "RemoteMP4ChapterExtractor", code: 1, userInfo: [NSLocalizedDescriptionKey: "No \(type) atom found"])
    }

    private static func parseChapters(fromMP4Window data: Data, durationHint: TimeInterval?, client: RangeClient) async throws -> [Chapter]?
    {
        guard let moov = findAtom(["moov"], in: data), moov.contentStart < moov.end else { return nil }
        let payload = data.subdata(in: moov.contentStart..<moov.end)
        return try await parseChapters(fromMoovPayload: payload, durationHint: durationHint, client: client)
    }

    private static func parseChapters(
        fromMoovPayload moovData: Data,
        durationHint: TimeInterval?,
        client: RangeClient
    ) async throws -> [Chapter]? {
        if let chapters = parseNeroChapters(from: moovData, durationHint: durationHint), !chapters.isEmpty {
            return chapters
        }

        let tracks = parseTracks(from: moovData)
        guard let chapterTrack = chooseChapterTrack(from: tracks) else { return nil }
        return try await buildTextTrackChapters(track: chapterTrack, durationHint: durationHint, client: client)
    }

    private static func parseTracks(from moov: Data) -> [Track] {
        childAtoms(in: moov).filter { $0.type == "trak" }.compactMap { trak in
            let data = moov
            let trackId = findAtom(["tkhd"], in: data, root: trak).flatMap { parseTrackId(data, atom: $0) }
            let mdia = findAtom(["mdia"], in: data, root: trak)
            let handler = mdia.flatMap { findAtom(["hdlr"], in: data, root: $0) }.flatMap { parseHandler(data, atom: $0) }
            let timescale = mdia.flatMap { findAtom(["mdhd"], in: data, root: $0) }.flatMap { parseTimescale(data, atom: $0) } ?? 1
            let stbl = mdia.flatMap { findAtom(["minf", "stbl"], in: data, root: $0) }
            let sampleDurations = stbl.flatMap { findAtom(["stts"], in: data, root: $0) }.map { parseSampleDurations(data, atom: $0) } ?? []
            let sampleSizes = stbl.flatMap { findAtom(["stsz"], in: data, root: $0) }.map { parseSampleSizes(data, atom: $0) } ?? []
            let chunkOffsets =
                stbl.flatMap { findAtom(["co64"], in: data, root: $0) }.map { parseChunkOffsets64(data, atom: $0) }
                ?? stbl.flatMap { findAtom(["stco"], in: data, root: $0) }.map { parseChunkOffsets32(data, atom: $0) }
                ?? []
            let sampleToChunk = stbl.flatMap { findAtom(["stsc"], in: data, root: $0) }.map { parseSampleToChunk(data, atom: $0) } ?? []
            let sampleOffsets = buildSampleOffsets(sampleSizes: sampleSizes, chunkOffsets: chunkOffsets, sampleToChunk: sampleToChunk)
            let refs = findAtom(["tref", "chap"], in: data, root: trak).map { parseChapterReferences(data, atom: $0) } ?? []

            guard let trackId else { return nil }
            return Track(
                id: trackId,
                handler: handler,
                timescale: timescale,
                sampleDurations: sampleDurations,
                sampleSizes: sampleSizes,
                sampleOffsets: sampleOffsets,
                chapterReferences: refs
            )
        }
    }

    private static func chooseChapterTrack(from tracks: [Track]) -> Track? {
        let referencedIds = Set(tracks.flatMap(\.chapterReferences))
        if let referencedText = tracks.first(where: { referencedIds.contains($0.id) && $0.isTextTrack }) {
            return referencedText
        }
        return tracks.first { $0.isTextTrack && !$0.sampleSizes.isEmpty && !$0.sampleOffsets.isEmpty }
    }

    private static func buildTextTrackChapters(track: Track, durationHint: TimeInterval?, client: RangeClient) async throws -> [Chapter]? {
        let count = min(track.sampleSizes.count, track.sampleOffsets.count)
        guard count > 0 else { return nil }

        let starts = sampleStarts(from: track.sampleDurations, count: count, timescale: track.timescale)
        var chapters: [Chapter] = []
        for index in 0..<count {
            let size = Int(track.sampleSizes[index])
            guard size > 0, size <= 64 * 1024 else { continue }
            let sample = try await client.read(start: Int64(track.sampleOffsets[index]), length: size).data
            let title = titleFromTextSample(sample) ?? "Chapter \(index + 1)"
            let start = starts[index]
            let end: TimeInterval
            if index + 1 < starts.count {
                end = starts[index + 1]
            } else if let durationHint, durationHint > start {
                end = durationHint
            } else {
                end = start
            }
            chapters.append(Chapter(id: "m4b-\(index)", start: start, end: end, title: title, index: index))
        }

        return chapters.isEmpty ? nil : chapters
    }

    private static func sampleStarts(from durations: [UInt32], count: Int, timescale: UInt32) -> [TimeInterval] {
        var starts: [TimeInterval] = []
        starts.reserveCapacity(count)
        var current: UInt64 = 0
        let scale = Double(max(timescale, 1))

        for index in 0..<count {
            starts.append(Double(current) / scale)
            if durations.indices.contains(index) {
                current += UInt64(durations[index])
            }
        }
        return starts
    }

    private static func parseNeroChapters(from moov: Data, durationHint: TimeInterval?) -> [Chapter]? {
        guard let chpl = findAtom(["udta", "chpl"], in: moov) ?? findAtom(["chpl"], in: moov) else { return nil }
        guard chpl.contentStart < chpl.end else { return nil }

        for countOffset in [8, 4] {
            let countIndex = chpl.contentStart + countOffset
            guard countIndex < chpl.end else { continue }
            let count = Int(moov[countIndex])
            guard count > 0, count < 255 else { continue }

            var cursor = countIndex + 1
            var starts: [TimeInterval] = []
            var titles: [String] = []
            for _ in 0..<count {
                guard cursor + 9 <= chpl.end else { break }
                let startRaw = UInt64.read(from: moov, at: cursor, byteCount: 8)
                cursor += 8
                let titleLength = Int(moov[cursor])
                cursor += 1
                guard titleLength >= 0, cursor + titleLength <= chpl.end else { break }
                let titleData = moov.subdata(in: cursor..<(cursor + titleLength))
                cursor += titleLength
                starts.append(Double(startRaw) / 10_000_000.0)
                titles.append(String(data: titleData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            }

            guard starts.count == count, !starts.isEmpty else { continue }
            return starts.enumerated().map { index, start in
                let end = index + 1 < starts.count ? starts[index + 1] : max(durationHint ?? start, start)
                let title = titles[index].isEmpty ? "Chapter \(index + 1)" : titles[index]
                return Chapter(id: "chpl-\(index)", start: start, end: end, title: title, index: index)
            }
        }

        return nil
    }

    private static func titleFromTextSample(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let candidates: [Data]
        if data.count >= 2 {
            let length = Int(UInt64.read(from: data, at: 0, byteCount: 2))
            if length > 0, 2 + length <= data.count {
                candidates = [data.subdata(in: 2..<(2 + length)), data]
            } else {
                candidates = [data]
            }
        } else {
            candidates = [data]
        }

        for candidate in candidates {
            if let string = String(data: candidate, encoding: .utf8)?.cleanChapterTitle, !string.isEmpty {
                return string
            }
            if let string = String(data: candidate, encoding: .utf16BigEndian)?.cleanChapterTitle, !string.isEmpty {
                return string
            }
        }
        return nil
    }

    private static func childAtoms(in data: Data, range: Range<Int>? = nil) -> [Atom] {
        let bounds = range ?? data.startIndex..<data.endIndex
        var atoms: [Atom] = []
        var cursor = bounds.lowerBound

        while cursor + 8 <= bounds.upperBound {
            let size32 = Int(UInt64.read(from: data, at: cursor, byteCount: 4))
            let type = data.asciiString(at: cursor + 4, count: 4)
            let headerSize: Int
            let size: Int
            if size32 == 1 {
                guard cursor + 16 <= bounds.upperBound else { break }
                headerSize = 16
                size = Int(UInt64.read(from: data, at: cursor + 8, byteCount: 8))
            } else if size32 == 0 {
                headerSize = 8
                size = bounds.upperBound - cursor
            } else {
                headerSize = 8
                size = size32
            }
            guard size >= headerSize, cursor + size <= bounds.upperBound else { break }
            atoms.append(Atom(type: type, start: cursor, headerSize: headerSize, size: size))
            cursor += size
        }

        return atoms
    }

    private static func findAtom(_ path: [String], in data: Data, root: Atom? = nil) -> Atom? {
        guard let first = path.first else { return root }
        let range = root.map { $0.contentStart..<$0.end }
        for atom in childAtoms(in: data, range: range) where atom.type == first {
            if path.count == 1 { return atom }
            if let found = findAtom(Array(path.dropFirst()), in: data, root: atom) {
                return found
            }
        }
        return nil
    }

    private static func parseTrackId(_ data: Data, atom: Atom) -> UInt32? {
        let version = data[atom.contentStart]
        let offset = atom.contentStart + (version == 1 ? 20 : 12)
        guard offset + 4 <= atom.end else { return nil }
        return UInt32(UInt64.read(from: data, at: offset, byteCount: 4))
    }

    private static func parseHandler(_ data: Data, atom: Atom) -> String? {
        let offset = atom.contentStart + 8
        guard offset + 4 <= atom.end else { return nil }
        return data.asciiString(at: offset, count: 4)
    }

    private static func parseTimescale(_ data: Data, atom: Atom) -> UInt32? {
        let version = data[atom.contentStart]
        let offset = atom.contentStart + (version == 1 ? 20 : 12)
        guard offset + 4 <= atom.end else { return nil }
        return UInt32(UInt64.read(from: data, at: offset, byteCount: 4))
    }

    private static func parseSampleDurations(_ data: Data, atom: Atom) -> [UInt32] {
        let start = atom.contentStart + 4
        guard start + 4 <= atom.end else { return [] }
        let entryCount = Int(UInt64.read(from: data, at: start, byteCount: 4))
        var cursor = start + 4
        var durations: [UInt32] = []
        for _ in 0..<entryCount {
            guard cursor + 8 <= atom.end else { break }
            let sampleCount = Int(UInt64.read(from: data, at: cursor, byteCount: 4))
            let duration = UInt32(UInt64.read(from: data, at: cursor + 4, byteCount: 4))
            durations.append(contentsOf: Array(repeating: duration, count: sampleCount))
            cursor += 8
        }
        return durations
    }

    private static func parseSampleSizes(_ data: Data, atom: Atom) -> [UInt32] {
        let start = atom.contentStart + 4
        guard start + 8 <= atom.end else { return [] }
        let sampleSize = UInt32(UInt64.read(from: data, at: start, byteCount: 4))
        let sampleCount = Int(UInt64.read(from: data, at: start + 4, byteCount: 4))
        if sampleSize > 0 {
            return Array(repeating: sampleSize, count: sampleCount)
        }
        var cursor = start + 8
        var sizes: [UInt32] = []
        for _ in 0..<sampleCount {
            guard cursor + 4 <= atom.end else { break }
            sizes.append(UInt32(UInt64.read(from: data, at: cursor, byteCount: 4)))
            cursor += 4
        }
        return sizes
    }

    private static func parseChunkOffsets32(_ data: Data, atom: Atom) -> [UInt64] {
        parseChunkOffsets(data, atom: atom, byteCount: 4)
    }

    private static func parseChunkOffsets64(_ data: Data, atom: Atom) -> [UInt64] {
        parseChunkOffsets(data, atom: atom, byteCount: 8)
    }

    private static func parseChunkOffsets(_ data: Data, atom: Atom, byteCount: Int) -> [UInt64] {
        let start = atom.contentStart + 4
        guard start + 4 <= atom.end else { return [] }
        let count = Int(UInt64.read(from: data, at: start, byteCount: 4))
        var cursor = start + 4
        var offsets: [UInt64] = []
        for _ in 0..<count {
            guard cursor + byteCount <= atom.end else { break }
            offsets.append(UInt64.read(from: data, at: cursor, byteCount: byteCount))
            cursor += byteCount
        }
        return offsets
    }

    private static func parseSampleToChunk(_ data: Data, atom: Atom) -> [(firstChunk: Int, samplesPerChunk: Int)] {
        let start = atom.contentStart + 4
        guard start + 4 <= atom.end else { return [] }
        let count = Int(UInt64.read(from: data, at: start, byteCount: 4))
        var cursor = start + 4
        var entries: [(Int, Int)] = []
        for _ in 0..<count {
            guard cursor + 12 <= atom.end else { break }
            let firstChunk = Int(UInt64.read(from: data, at: cursor, byteCount: 4))
            let samplesPerChunk = Int(UInt64.read(from: data, at: cursor + 4, byteCount: 4))
            entries.append((firstChunk, samplesPerChunk))
            cursor += 12
        }
        return entries
    }

    private static func buildSampleOffsets(
        sampleSizes: [UInt32],
        chunkOffsets: [UInt64],
        sampleToChunk: [(firstChunk: Int, samplesPerChunk: Int)]
    ) -> [UInt64] {
        guard !sampleSizes.isEmpty, !chunkOffsets.isEmpty else { return [] }
        var result: [UInt64] = []
        var sampleIndex = 0

        for chunkIndex in 1...chunkOffsets.count {
            let samplesPerChunk = samplesPerChunk(for: chunkIndex, entries: sampleToChunk)
            var offset = chunkOffsets[chunkIndex - 1]
            for _ in 0..<samplesPerChunk {
                guard sampleIndex < sampleSizes.count else { return result }
                result.append(offset)
                offset += UInt64(sampleSizes[sampleIndex])
                sampleIndex += 1
            }
        }

        return result
    }

    private static func samplesPerChunk(for chunkIndex: Int, entries: [(firstChunk: Int, samplesPerChunk: Int)]) -> Int {
        guard !entries.isEmpty else { return 1 }
        var current = entries[0].samplesPerChunk
        for entry in entries where entry.firstChunk <= chunkIndex {
            current = entry.samplesPerChunk
        }
        return max(current, 1)
    }

    private static func parseChapterReferences(_ data: Data, atom: Atom) -> [UInt32] {
        var cursor = atom.contentStart
        var refs: [UInt32] = []
        while cursor + 4 <= atom.end {
            refs.append(UInt32(UInt64.read(from: data, at: cursor, byteCount: 4)))
            cursor += 4
        }
        return refs
    }
}

private struct RangeClient {
    let url: URL
    let headers: [String: String]

    func contentLength() async throws -> Int64? {
        if url.isFileURL {
            return try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
            (200...299).contains(http.statusCode)
        else {
            return nil
        }
        return totalSize(from: http)
    }

    func read(start: Int64, length: Int) async throws -> (data: Data, totalSize: Int64?) {
        if url.isFileURL {
            guard start >= 0, length > 0 else {
                return (Data(), try await contentLength())
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(start))
            return (try handle.read(upToCount: length) ?? Data(), try await contentLength())
        }

        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let end = start + Int64(length) - 1
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return (data, nil) }
        guard (200...299).contains(http.statusCode) else {
            throw NSError(
                domain: "RemoteMP4ChapterExtractor",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
            )
        }
        return (data, totalSize(from: http))
    }

    private func totalSize(from response: HTTPURLResponse) -> Int64? {
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
            let total = contentRange.split(separator: "/").last,
            let value = Int64(total)
        {
            return value
        }
        if response.statusCode == 200,
            let length = response.value(forHTTPHeaderField: "Content-Length"),
            let value = Int64(length)
        {
            return value
        }
        return nil
    }
}

private extension UInt64 {
    static func read(from data: Data, at offset: Int, byteCount: Int) -> UInt64 {
        guard byteCount > 0, offset >= data.startIndex, offset + byteCount <= data.endIndex else { return 0 }
        var value: UInt64 = 0
        for byte in data[offset..<(offset + byteCount)] {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }
}

private extension Data {
    func asciiString(at offset: Int, count: Int) -> String {
        guard offset >= startIndex, offset + count <= endIndex else { return "" }
        return String(bytes: self[offset..<(offset + count)], encoding: .ascii) ?? ""
    }
}

private extension String {
    var cleanChapterTitle: String {
        filter { scalar in
            guard let value = scalar.unicodeScalars.first?.value else { return true }
            return value >= 32 || scalar == "\n" || scalar == "\t"
        }
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
