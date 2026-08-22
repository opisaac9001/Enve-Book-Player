import Compression
import Foundation
import ReadiumZIPFoundation

struct KF8Book {
    var metadata: MobiMetadata
    var parts: [KF8Part]
    var cssFlows: [String]
    var images: [(name: String, data: Data)]
    var fonts: [(name: String, data: Data)]
    var chapterEntries: [InlineFileposTOCEntry]
    var ncxEntries: [KF8NCXEntry]
    var guideEntries: [KF8GuideEntry]
    var encoding: String.Encoding
}

struct KF8Part {
    var filename: String
    var content: String
}

struct KF8NCXEntry {
    var label: String
    var position: Int
    var length: Int
    var fragmentGroupIndex: Int
}

struct KF8GuideEntry {
    var type: String
    var title: String
    var fragmentIndex: Int
    var offset: Int
}

struct INDXTagDef {
    var tag: Int
    var numValues: Int
    var bitmask: Int
}

struct INDXEntry {
    var label: String
    var tagValues: [Int: [Int]]
}

enum KF8Reader {

    static func isKF8(record0: Data, headerLength: UInt32) -> Bool {
        let bookType = record0.readBE32(at: 24)
        if bookType == 258 { return true }

        let mobi: Int = 16
        let fdstIdx = record0.readBE32(at: mobi + 176)
        let skelIdx = record0.readBE32(at: mobi + 232)
        return fdstIdx != 0xFFFF_FFFF && fdstIdx != 0 && skelIdx != 0xFFFF_FFFF && skelIdx != 0
    }

    static func parseKF8(
        db: KF8PalmDB,
        record0: Data,
        metadata: MobiMetadata,
        encoding: String.Encoding
    ) throws -> KF8Book {
        try Task.checkCancellation()
        let mobi: Int = 16

        let compression = record0.readBE16(at: 0)
        let textRecordCount = Int(record0.readBE16(at: 8))
        let firstImageRecord = Int(record0.readBE32(at: mobi + 92))
        let huffRecordOffset = Int(record0.readBE32(at: mobi + 96))
        let huffRecordCount = Int(record0.readBE32(at: mobi + 100))
        let _ = Int(record0.readBE32(at: mobi + 64))
        let fdstRecordIndex = Int(record0.readBE32(at: mobi + 176))
        let fdstFlowCount = Int(record0.readBE32(at: mobi + 180))
        let skelINDXRecord = Int(record0.readBE32(at: mobi + 232))
        let fragINDXRecord = Int(record0.readBE32(at: mobi + 236))
        let ncxINDXRecord = Int(record0.readBE32(at: mobi + 228))
        let guideINDXRecord = Int(record0.readBE32(at: mobi + 244))
        let extraDataFlags = Int(record0.readBE32(at: mobi + 224))

        let allText = try decompressTextRecords(
            db: db,
            compression: compression,
            textRecordCount: textRecordCount,
            huffRecordOffset: huffRecordOffset,
            huffRecordCount: huffRecordCount,
            extraDataFlags: extraDataFlags
        )

        guard !allText.isEmpty else {
            throw MobiConversionError.emptyContent
        }

        let flows = try parseFDST(
            db: db,
            fdstRecordIndex: fdstRecordIndex,
            fdstFlowCount: fdstFlowCount,
            allText: allText,
            encoding: encoding
        )

        guard !flows.isEmpty else {
            throw MobiConversionError.emptyContent
        }

        let mainHTML = flows[0]
        let cssFlows = Array(flows.dropFirst())

        var flow0Data: Data = Data(mainHTML.utf8)
        if fdstRecordIndex > 0, fdstRecordIndex < db.numRecords,
            let fdstRaw = try? db.record(fdstRecordIndex),
            fdstRaw.count >= 20
        {
            let f0Start = Int(fdstRaw.readBE32(at: 12))
            let f0End = Int(fdstRaw.readBE32(at: 16))
            if f0Start < f0End, f0End <= allText.count {
                flow0Data = allText.withUnsafeBytes { ptr in
                    Data(ptr[f0Start..<f0End])
                }
            }
        }

        _ = try parseINDXTable(
            db: db,
            headerRecord: skelINDXRecord
        )

        let fragmentEntries = try parseINDXTable(
            db: db,
            headerRecord: fragINDXRecord
        )

        var ncxEntries: [KF8NCXEntry] = []
        if ncxINDXRecord > 0 && ncxINDXRecord < db.numRecords {
            let ncxRaw = try parseINDXTable(db: db, headerRecord: ncxINDXRecord)
            ncxEntries = ncxRaw.map { entry in
                KF8NCXEntry(
                    label: entry.label,
                    position: entry.tagValues[1]?.first ?? 0,
                    length: entry.tagValues[2]?.first ?? 0,
                    fragmentGroupIndex: entry.tagValues[3]?.first ?? 0
                )
            }
        }

        var guideEntries: [KF8GuideEntry] = []
        if guideINDXRecord > 0 && guideINDXRecord < db.numRecords {
            let guideRaw = try parseINDXTable(db: db, headerRecord: guideINDXRecord)
            guideEntries = guideRaw.map { entry in
                let tag6 = entry.tagValues[6] ?? [0, 0]
                return KF8GuideEntry(
                    type: entry.label,
                    title: entry.label,
                    fragmentIndex: tag6.count > 0 ? tag6[0] : 0,
                    offset: tag6.count > 1 ? tag6[1] : 0
                )
            }
        }

        let parts = buildParts(
            flow0Data: flow0Data,
            fragmentEntries: fragmentEntries,
            encoding: encoding
        )

        var images: [(name: String, data: Data)] = []
        if firstImageRecord > 0 && firstImageRecord < db.numRecords {
            for i in firstImageRecord..<db.numRecords {
                try Task.checkCancellation()
                guard let imgData = try? db.record(i), imgData.count > 4 else { continue }

                if imgData[0...3] == Data([0x49, 0x4E, 0x44, 0x58]) || imgData[0...3] == Data([0x46, 0x44, 0x53, 0x54])
                    || imgData[0...3] == Data([0x46, 0x4C, 0x49, 0x53]) || imgData[0...3] == Data([0x46, 0x43, 0x49, 0x53])
                    || imgData[0...3] == Data([0x44, 0x41, 0x54, 0x50]) || imgData[0...3] == Data([0x48, 0x55, 0x46, 0x46])
                    || imgData[0...3] == Data([0x43, 0x44, 0x49, 0x43]) || imgData[0...3] == Data([0x52, 0x45, 0x53, 0x43])
                    || imgData[0...3] == Data([0x53, 0x52, 0x43, 0x53])
                {
                    continue
                }
                if let ext = kf8ImageExtension(for: imgData) {
                    let idx = images.count
                    images.append((name: "image\(String(format: "%04d", idx)).\(ext)", data: imgData))
                } else if imgData[0...3] == Data([0x46, 0x4F, 0x4E, 0x54]) {

                    continue
                }
            }
        }

        var fonts: [(name: String, data: Data)] = []
        if firstImageRecord > 0 && firstImageRecord < db.numRecords {
            for i in firstImageRecord..<db.numRecords {
                try Task.checkCancellation()
                guard let recData = try? db.record(i), recData.count > 16 else { continue }
                if recData[0...3] == Data([0x46, 0x4F, 0x4E, 0x54]) {
                    if let font = extractFont(from: recData, index: fonts.count) {
                        fonts.append(font)
                    }
                }
            }
        }

        let rewrittenParts = parts.map { part -> KF8Part in
            var content = part.content
            content = rewriteKindleURIs(content, images: images, cssCount: cssFlows.count)
            return KF8Part(filename: part.filename, content: content)
        }

        let chapterEntries = InlineFileposTOCHelper.parseEntries(from: flow0Data, encoding: encoding)
        let finalParts: [KF8Part]
        if rewrittenParts.count == 1, !chapterEntries.isEmpty {
            let sourceHTML =
                String(data: flow0Data, encoding: encoding)
                ?? String(data: flow0Data, encoding: .isoLatin1)
                ?? ""
            let anchoredHTML = InlineFileposTOCHelper.injectAnchorsAndRewriteLinks(in: sourceHTML, entries: chapterEntries)
            let rewrittenHTML = rewriteKindleURIs(anchoredHTML, images: images, cssCount: cssFlows.count)
            finalParts = [KF8Part(filename: rewrittenParts[0].filename, content: wrapHTML(rewrittenHTML))]
        } else {
            finalParts = rewrittenParts
        }

        return KF8Book(
            metadata: metadata,
            parts: finalParts,
            cssFlows: cssFlows,
            images: images,
            fonts: fonts,
            chapterEntries: chapterEntries,
            ncxEntries: ncxEntries,
            guideEntries: guideEntries,
            encoding: encoding
        )
    }

    private static func decompressTextRecords(
        db: KF8PalmDB,
        compression: UInt16,
        textRecordCount: Int,
        huffRecordOffset: Int,
        huffRecordCount: Int,
        extraDataFlags: Int
    ) throws -> Data {
        guard textRecordCount > 0 else { return Data() }

        let firstText = 1
        let lastText = firstText + textRecordCount - 1
        guard lastText < db.numRecords else {
            throw MobiConversionError.malformed("Text records extend beyond file")
        }

        var rawText = Data()
        rawText.reserveCapacity(textRecordCount * 4096)

        if compression == 17480 {

            guard huffRecordOffset > 0, huffRecordOffset + huffRecordCount <= db.numRecords else {
                throw MobiConversionError.malformed("Huffman record index out of range")
            }
            let huffRecord = try db.record(huffRecordOffset)
            var cdicRecords: [Data] = []
            for i in (huffRecordOffset + 1)..<(huffRecordOffset + huffRecordCount) {
                cdicRecords.append(try db.record(i))
            }
            let decoder = try KF8HuffcdicDecoder(huffRecord: huffRecord, cdicRecords: cdicRecords)
            for i in firstText...lastText {
                let rec = try db.record(i)
                let cleaned = stripTrailingData(rec, flags: extraDataFlags)
                rawText.append(decoder.decompress(cleaned))
            }
        } else if compression == 2 {

            for i in firstText...lastText {
                let rec = try db.record(i)
                let cleaned = stripTrailingData(rec, flags: extraDataFlags)
                rawText.append(KF8PalmDocDecoder.decompress(cleaned))
            }
        } else if compression == 1 {

            for i in firstText...lastText {
                rawText.append(try db.record(i))
            }
        } else {
            throw MobiConversionError.malformed("Unknown compression type \(compression)")
        }

        return rawText
    }

    private static func stripTrailingData(_ record: Data, flags: Int) -> Data {
        guard record.count > 2, flags > 0 else { return record }
        var d = Array(record)

        for bit in stride(from: 15, through: 1, by: -1) {
            guard flags & (1 << bit) != 0, d.count > 0 else { continue }
            let size = getTrailingEntrySize(d)
            guard size > 0, size <= d.count else { continue }
            d.removeLast(size)
        }

        if flags & 1 != 0, !d.isEmpty {
            let mb = Int(d.last! & 0x03) + 1
            if mb <= d.count {
                d.removeLast(mb)
            }
        }

        return Data(d)
    }

    private static func getTrailingEntrySize(_ data: [UInt8]) -> Int {
        var result = 0
        var bitpos = 0
        for i in stride(from: data.count - 1, through: max(0, data.count - 4), by: -1) {
            let b = data[i]
            result |= Int(b & 0x7F) << bitpos
            bitpos += 7
            if b & 0x80 != 0 { break }
        }
        return result
    }

    private static func parseFDST(
        db: KF8PalmDB,
        fdstRecordIndex: Int,
        fdstFlowCount: Int,
        allText: Data,
        encoding: String.Encoding
    ) throws -> [String] {
        guard fdstRecordIndex > 0, fdstRecordIndex < db.numRecords else {

            let html = String(data: allText, encoding: encoding) ?? String(data: allText, encoding: .isoLatin1) ?? ""
            return [html]
        }

        let fdstData = try db.record(fdstRecordIndex)
        guard fdstData.count >= 12,
            fdstData[0] == 0x46, fdstData[1] == 0x44,
            fdstData[2] == 0x53, fdstData[3] == 0x54
        else {

            let html = String(data: allText, encoding: encoding) ?? String(data: allText, encoding: .isoLatin1) ?? ""
            return [html]
        }

        let count = Int(fdstData.readBE32(at: 8))
        var flows: [String] = []

        for i in 0..<count {
            let base = 12 + i * 8
            guard base + 8 <= fdstData.count else { break }
            let flowStart = Int(fdstData.readBE32(at: base))
            let flowEnd = Int(fdstData.readBE32(at: base + 4))

            guard flowStart <= flowEnd, flowEnd <= allText.count else {
                continue
            }

            let flowData = allText[allText.startIndex.advanced(by: flowStart)..<allText.startIndex.advanced(by: flowEnd)]
            let flowString =
                String(data: flowData, encoding: encoding)
                ?? String(data: flowData, encoding: .isoLatin1)
                ?? ""
            flows.append(flowString)
        }

        return flows
    }

    private static func parseINDXTable(
        db: KF8PalmDB,
        headerRecord: Int
    ) throws -> [INDXEntry] {
        guard headerRecord > 0, headerRecord < db.numRecords else { return [] }

        let hdrData = try db.record(headerRecord)
        guard hdrData.count >= 192,
            hdrData[0] == 0x49, hdrData[1] == 0x4E,
            hdrData[2] == 0x44, hdrData[3] == 0x58
        else {
            return []
        }

        let (tagDefs, controlByteCount) = parseTagx(from: hdrData)

        let hdrEntryCount = Int(hdrData.readBE32(at: 24))

        var allEntries: [INDXEntry] = []
        for dataOffset in 1...hdrEntryCount {
            let dataIdx = headerRecord + dataOffset
            guard dataIdx < db.numRecords else { break }
            let dataRec = try db.record(dataIdx)
            guard dataRec.count >= 24,
                dataRec[0] == 0x49, dataRec[1] == 0x4E,
                dataRec[2] == 0x44, dataRec[3] == 0x58
            else {
                break
            }

            let entries = parseINDXEntries(
                from: dataRec,
                tagDefs: tagDefs,
                controlByteCount: controlByteCount
            )
            allEntries.append(contentsOf: entries)
        }

        return allEntries
    }

    private static func parseTagx(from record: Data) -> ([INDXTagDef], Int) {

        guard let tagxPos = findMagic(in: record, magic: [0x54, 0x41, 0x47, 0x58]) else {
            return ([], 0)
        }

        let tagxLen = Int(record.readBE32(at: tagxPos + 4))
        let controlByteCount = Int(record.readBE32(at: tagxPos + 8))

        var tags: [INDXTagDef] = []
        var pos = tagxPos + 12
        while pos + 4 <= tagxPos + tagxLen {
            let tag = Int(record[pos])
            let numValues = Int(record[pos + 1])
            let bitmask = Int(record[pos + 2])
            let endFlag = record[pos + 3]
            if endFlag == 1 { break }
            tags.append(INDXTagDef(tag: tag, numValues: numValues, bitmask: bitmask))
            pos += 4
        }

        return (tags, controlByteCount)
    }

    private static func parseINDXEntries(
        from record: Data,
        tagDefs: [INDXTagDef],
        controlByteCount: Int
    ) -> [INDXEntry] {
        let idxtOffset = Int(record.readBE32(at: 20))
        let entryCount = Int(record.readBE32(at: 24))

        guard idxtOffset + 4 <= record.count,
            record[idxtOffset] == 0x49, record[idxtOffset + 1] == 0x44,
            record[idxtOffset + 2] == 0x58, record[idxtOffset + 3] == 0x54
        else {
            return []
        }

        var offsets: [Int] = []
        for i in 0..<entryCount {
            let pos = idxtOffset + 4 + i * 2
            guard pos + 2 <= record.count else { break }
            offsets.append(Int(record.readBE16(at: pos)))
        }

        var entries: [INDXEntry] = []
        for i in 0..<offsets.count {
            let off = offsets[i]
            let nextOff = i + 1 < offsets.count ? offsets[i + 1] : idxtOffset
            guard off < record.count else { continue }

            let labelLen = Int(record[off])
            let labelEnd = off + 1 + labelLen
            guard labelEnd <= record.count else { continue }

            let labelData = record[(off + 1)..<labelEnd]
            let label = String(data: labelData, encoding: .utf8) ?? String(data: labelData, encoding: .isoLatin1) ?? ""

            let tagDataSlice = record[labelEnd..<min(nextOff, record.count)]
            let tagData = Data(tagDataSlice)

            let tagValues = decodeTagValues(
                tagData: tagData,
                tagDefs: tagDefs,
                controlByteCount: controlByteCount
            )

            entries.append(INDXEntry(label: label, tagValues: tagValues))
        }

        return entries
    }

    private static func decodeTagValues(
        tagData: Data,
        tagDefs: [INDXTagDef],
        controlByteCount: Int
    ) -> [Int: [Int]] {
        guard !tagData.isEmpty, !tagDefs.isEmpty, controlByteCount > 0 else { return [:] }
        guard controlByteCount <= tagData.count else { return [:] }

        let controlBytes = Array(tagData.prefix(controlByteCount))
        var pos = controlByteCount
        var result: [Int: [Int]] = [:]

        for (j, tagDef) in tagDefs.enumerated() {
            let cbIdx = j / 4
            guard cbIdx < controlBytes.count else { continue }
            guard controlBytes[cbIdx] & UInt8(tagDef.bitmask) != 0 else { continue }

            var values: [Int] = []
            if tagDef.numValues > 0 {
                for _ in 0..<tagDef.numValues {
                    guard pos < tagData.count else { break }
                    let (v, newPos) = decodeVWI(tagData, pos: pos)
                    values.append(v)
                    pos = newPos
                }
            } else {

                guard pos < tagData.count else { continue }
                let (count, countPos) = decodeVWI(tagData, pos: pos)
                pos = countPos
                for _ in 0..<count {
                    guard pos < tagData.count else { break }
                    let (v, newPos) = decodeVWI(tagData, pos: pos)
                    values.append(v)
                    pos = newPos
                }
            }

            result[tagDef.tag] = values
        }

        return result
    }

    private static func decodeVWI(_ data: Data, pos: Int) -> (Int, Int) {
        var result = 0
        var p = pos
        while p < data.count {
            let b = Int(data[p])
            result = (result << 7) | (b & 0x7F)
            p += 1
            if b & 0x80 != 0 {
                return (result, p)
            }
        }
        return (result, p)
    }

    private static func findMagic(in data: Data, magic: [UInt8]) -> Int? {
        guard magic.count <= data.count else { return nil }
        let magicData = Data(magic)
        if let range = data.range(of: magicData) {
            return data.distance(from: data.startIndex, to: range.lowerBound)
        }
        return nil
    }

    private static func rewriteKindleURIs(_ content: String, images: [(name: String, data: Data)], cssCount: Int) -> String {
        var result = content

        if let regex = try? NSRegularExpression(pattern: #"kindle:embed:([0-9A-V]+)\?mime=[^"]*"#, options: []) {
            let nsRange = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, range: nsRange)
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: result),
                    let indexRange = Range(match.range(at: 1), in: result)
                else { continue }
                let b32Str = String(result[indexRange])
                guard let imgIndex = decodeKindleBase32(b32Str), imgIndex > 0, imgIndex <= images.count else { continue }
                let img = images[imgIndex - 1]
                result.replaceSubrange(fullRange, with: "../Images/\(img.name)")
            }
        }

        if let regex = try? NSRegularExpression(pattern: #"kindle:flow:([0-9A-V]+)\?mime=[^"]*"#, options: []) {
            let nsRange = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, range: nsRange)
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: result),
                    let indexRange = Range(match.range(at: 1), in: result)
                else { continue }
                let b32Str = String(result[indexRange])
                guard let flowIndex = decodeKindleBase32(b32Str), flowIndex > 0, flowIndex <= cssCount else { continue }
                result.replaceSubrange(fullRange, with: "../Styles/style\(flowIndex - 1).css")
            }
        }

        if let regex = try? NSRegularExpression(pattern: #"kindle:pos:fid:[0-9A-V]+:off:[0-9A-V]+"#, options: []) {
            let nsRange = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: nsRange, withTemplate: "#")
        }

        return result
    }

    private static func decodeKindleBase32(_ str: String) -> Int? {
        var result = 0
        let zero = Character("0").asciiValue ?? 0x30
        let upperA = Character("A").asciiValue ?? 0x41
        for ch in str {
            guard let ascii = ch.asciiValue else { return nil }
            result *= 32
            if ch >= "0" && ch <= "9" {
                result += Int(ascii - zero)
            } else if ch >= "A" && ch <= "V" {
                result += 10 + Int(ascii - upperA)
            } else {
                return nil
            }
        }
        return result
    }

    private static func buildParts(
        flow0Data: Data,
        fragmentEntries: [INDXEntry],
        encoding: String.Encoding
    ) -> [KF8Part] {
        guard !flow0Data.isEmpty else { return [] }

        let fileStarts: [Int] = fragmentEntries.compactMap { entry in
            guard let tag6 = entry.tagValues[6], tag6.count >= 2 else { return nil }
            return tag6[1]
        }.sorted()

        if fileStarts.isEmpty {

            let html =
                String(data: flow0Data, encoding: encoding)
                ?? String(data: flow0Data, encoding: .isoLatin1) ?? ""
            return buildPartsByHTMLSplit(mainHTML: html)
        }

        var parts: [KF8Part] = []
        for (i, start) in fileStarts.enumerated() {
            let end = i + 1 < fileStarts.count ? fileStarts[i + 1] : flow0Data.count
            guard start >= 0, start < end, end <= flow0Data.count else { continue }

            let chunkData = flow0Data.withUnsafeBytes { ptr in
                Data(ptr[start..<end])
            }
            var chunk =
                String(data: chunkData, encoding: encoding)
                ?? String(data: chunkData, encoding: .isoLatin1)
                ?? ""

            if let bodyCloseRange = chunk.range(of: "</body>", options: [.caseInsensitive, .backwards]),
                let htmlCloseRange = chunk.range(of: "</html>", options: [.caseInsensitive, .backwards]),
                bodyCloseRange.lowerBound < htmlCloseRange.lowerBound
            {

                let afterHTML = String(chunk[htmlCloseRange.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let beforeBodyClose = String(chunk[..<bodyCloseRange.lowerBound])

                if afterHTML.isEmpty {
                    chunk = beforeBodyClose + "</body></html>"
                } else {
                    chunk = beforeBodyClose + "\n" + afterHTML + "\n</body></html>"
                }
            }

            parts.append(
                KF8Part(
                    filename: String(format: "part%04d.html", i + 1),
                    content: wrapHTML(chunk)
                )
            )
        }

        return parts.isEmpty
            ? [
                KF8Part(
                    filename: "part0001.html",
                    content: wrapHTML(String(data: flow0Data, encoding: encoding) ?? "")
                )
            ]
            : parts
    }

    private static func buildPartsByHTMLSplit(mainHTML: String) -> [KF8Part] {
        var splits: [String] = []
        var searchFrom = mainHTML.startIndex

        docSearch: while searchFrom < mainHTML.endIndex {

            let xmlStart = mainHTML.range(
                of: "<?xml",
                options: .caseInsensitive,
                range: searchFrom..<mainHTML.endIndex
            )?.lowerBound
            let htmlStart = mainHTML.range(
                of: "<html",
                options: .caseInsensitive,
                range: searchFrom..<mainHTML.endIndex
            )?.lowerBound

            let docStart: String.Index
            switch (xmlStart, htmlStart) {
            case let (xs?, hs?): docStart = xs < hs ? xs : hs
            case let (xs?, nil): docStart = xs
            case let (nil, hs?): docStart = hs
            default: break docSearch
            }

            guard
                let closeRange = mainHTML.range(
                    of: "</html>",
                    options: .caseInsensitive,
                    range: docStart..<mainHTML.endIndex
                )
            else {

                let part = String(mainHTML[docStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !part.isEmpty { splits.append(part) }
                break
            }

            let part = String(mainHTML[docStart..<closeRange.upperBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty { splits.append(part) }
            searchFrom = closeRange.upperBound
        }

        if splits.isEmpty {
            splits = [mainHTML]
        }

        return splits.enumerated().map { idx, content in
            KF8Part(
                filename: String(format: "part%04d.html", idx + 1),
                content: wrapHTML(content)
            )
        }
    }

    private static func wrapHTML(_ content: String) -> String {
        var normalized = content

        if let mbpRegex = try? NSRegularExpression(pattern: "</?mbp:[^>]*>", options: .caseInsensitive) {
            let range = NSRange(normalized.startIndex..., in: normalized)
            normalized = mbpRegex.stringByReplacingMatches(in: normalized, range: range, withTemplate: "")
        }

        if let xmlDeclRegex = try? NSRegularExpression(pattern: "<\\?xml[^?]*\\?>", options: .caseInsensitive) {
            let range = NSRange(normalized.startIndex..., in: normalized)
            normalized = xmlDeclRegex.stringByReplacingMatches(in: normalized, range: range, withTemplate: "")
        }
        if let doctypeRegex = try? NSRegularExpression(pattern: "<!DOCTYPE[^>]*>", options: .caseInsensitive) {
            let range = NSRange(normalized.startIndex..., in: normalized)
            normalized = doctypeRegex.stringByReplacingMatches(in: normalized, range: range, withTemplate: "")
        }
        normalized = normalized.replacingOccurrences(
            of: " xmlns=\"http://www.w3.org/1999/xhtml\"",
            with: "",
            options: .caseInsensitive
        )

        normalized = normalized.replacingOccurrences(of: "\u{0000}", with: "")

        if let closeRange = normalized.range(of: "</html>", options: [.caseInsensitive, .backwards]) {
            normalized = String(normalized[..<closeRange.upperBound])
        }

        let lower = normalized.lowercased()
        if lower.contains("<html") {
            return "<!DOCTYPE html>\n" + ensureUTF8Head(in: normalized)
        }

        return "<!DOCTYPE html>\n" + "<html>\n" + "<head><meta charset=\"utf-8\"/><title></title></head>\n" + "<body>\(normalized)</body>\n"
            + "</html>"
    }

    private static func ensureUTF8Head(in html: String) -> String {
        var html = html
        let hasCharset =
            html.range(
                of: #"<meta\s+charset\s*=\s*["'][^"']+["']\s*/?>"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        let hasTitle = html.range(of: #"<title\b[^>]*>.*?</title>"#, options: [.regularExpression, .caseInsensitive]) != nil
        let headInsertions = (hasCharset ? "" : "<meta charset=\"utf-8\"/>") + (hasTitle ? "" : "<title></title>")

        guard !headInsertions.isEmpty else { return html }

        if let headClose = html.range(of: "</head>", options: .caseInsensitive) {
            html.insert(contentsOf: headInsertions, at: headClose.lowerBound)
            return html
        }

        if let htmlOpen = html.range(of: #"<html\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            html.insert(contentsOf: "<head>\(headInsertions)</head>", at: htmlOpen.upperBound)
            return html
        }

        return "<html><head>\(headInsertions)</head><body>\(html)</body></html>"
    }

    private static func extractFont(from record: Data, index: Int) -> (name: String, data: Data)? {
        guard record.count > 24,
            record[0] == 0x46, record[1] == 0x4F, record[2] == 0x4E, record[3] == 0x54
        else {
            return nil
        }

        let uncompressedSize = Int(record.readBE32(at: 4))
        let flags = record.readBE32(at: 8)
        let dataOffset = Int(record.readBE32(at: 12))
        let xorKeyLen = Int(record.readBE32(at: 16))
        let xorKeyOffset = Int(record.readBE32(at: 20))

        guard dataOffset < record.count else { return nil }

        var fontData: Data
        if flags & 0x0002 != 0 {

            let compressed = record[dataOffset...]
            guard let decompressed = try? zlibDecompress(Data(compressed), expectedSize: uncompressedSize) else {
                return nil
            }
            fontData = decompressed
        } else {
            fontData = Data(record[dataOffset...])
        }

        if xorKeyLen > 0 && xorKeyOffset > 0 && xorKeyOffset + xorKeyLen <= record.count {
            let xorKey = Array(record[xorKeyOffset..<(xorKeyOffset + xorKeyLen)])
            let deobfLen = min(1040, fontData.count)
            for i in 0..<deobfLen {
                fontData[i] ^= xorKey[i % xorKey.count]
            }
        }

        let ext: String
        if fontData.count >= 4 {
            if fontData[0] == 0x00 && fontData[1] == 0x01 && fontData[2] == 0x00 && fontData[3] == 0x00 {
                ext = "ttf"
            } else if fontData[0] == 0x4F && fontData[1] == 0x54 && fontData[2] == 0x54 && fontData[3] == 0x4F {
                ext = "otf"
            } else if fontData[0] == 0x77 && fontData[1] == 0x4F && fontData[2] == 0x46 && fontData[3] == 0x46 {
                ext = "woff"
            } else if fontData[0] == 0x77 && fontData[1] == 0x4F && fontData[2] == 0x46 && fontData[3] == 0x32 {
                ext = "woff2"
            } else {
                ext = "ttf"
            }
        } else {
            ext = "ttf"
        }

        let name = "font\(String(format: "%04d", index)).\(ext)"
        return (name: name, data: fontData)
    }

    private static func zlibDecompress(_ compressed: Data, expectedSize: Int) throws -> Data {

        var decompressed = Data(count: expectedSize + 1024)
        let result = compressed.withUnsafeBytes { srcPtr -> Int in
            decompressed.withUnsafeMutableBytes { dstPtr -> Int in
                guard let src = srcPtr.baseAddress,
                    let dst = dstPtr.baseAddress
                else { return -1 }
                let dstLen = dstPtr.count
                let srcLen = srcPtr.count
                let status = compression_decode_buffer(
                    dst.assumingMemoryBound(to: UInt8.self),
                    dstLen,
                    src.assumingMemoryBound(to: UInt8.self),
                    srcLen,
                    nil,
                    COMPRESSION_ZLIB
                )
                return status > 0 ? status : -1
            }
        }
        guard result > 0 else { throw MobiConversionError.malformed("Failed to decompress font") }
        return decompressed.prefix(result)
    }

    private static func kf8ImageExtension(for data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        if data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF { return "jpg" }
        if data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47 { return "png" }
        if data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46 { return "gif" }
        if data.count >= 12,
            data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46,
            data[8] == 0x57, data[9] == 0x45, data[10] == 0x42, data[11] == 0x50
        {
            return "webp"
        }
        return nil
    }

    static func writeEPUB(book: KF8Book, to outputURL: URL) async throws {
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let archive = try await Archive(url: outputURL, accessMode: .create)
        let meta = book.metadata

        let mimetypeData = Data("application/epub+zip".utf8)
        try await archive.addEntry(
            with: "mimetype",
            type: .file,
            uncompressedSize: Int64(mimetypeData.count),
            compressionMethod: .none
        ) { @Sendable position, size in zipEntryChunk(from: mimetypeData, position: position, size: size) }

        let containerXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """
        try await addTextEntry(archive: archive, path: "META-INF/container.xml", content: containerXML)

        let titleEscaped = xmlEscapeKF8(meta.title)
        let authorEscaped = xmlEscapeKF8(meta.author ?? "Unknown Author")

        var manifestItems = ""
        var spineItems = ""
        for (i, part) in book.parts.enumerated() {
            try Task.checkCancellation()
            let id = "part\(i)"
            manifestItems += "    <item id=\"\(id)\" href=\"Text/\(part.filename)\" media-type=\"text/html\"/>\n"
            spineItems += "    <itemref idref=\"\(id)\"/>\n"
        }

        for (i, _) in book.cssFlows.enumerated() {
            manifestItems += "    <item id=\"css\(i)\" href=\"Styles/style\(i).css\" media-type=\"text/css\"/>\n"
        }

        for (i, img) in book.images.enumerated() {
            let ext = String(img.name.split(separator: ".").last ?? "jpg")
            let mime: String
            switch ext {
            case "jpg": mime = "image/jpeg"
            case "png": mime = "image/png"
            case "gif": mime = "image/gif"
            case "webp": mime = "image/webp"
            default: mime = "image/jpeg"
            }
            manifestItems += "    <item id=\"img\(i)\" href=\"Images/\(img.name)\" media-type=\"\(mime)\"/>\n"
        }

        for (i, font) in book.fonts.enumerated() {
            let ext = String(font.name.split(separator: ".").last ?? "ttf")
            let mime: String
            switch ext {
            case "otf": mime = "application/vnd.ms-opentype"
            case "woff": mime = "application/font-woff"
            case "woff2": mime = "font/woff2"
            default: mime = "application/x-font-truetype"
            }
            manifestItems += "    <item id=\"font\(i)\" href=\"Fonts/\(font.name)\" media-type=\"\(mime)\"/>\n"
        }

        manifestItems += "    <item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>\n"

        let opfXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:title>\(titleEscaped)</dc:title>
                <dc:creator opf:role="aut">\(authorEscaped)</dc:creator>
                \(meta.publisher.map { "<dc:publisher>\(xmlEscapeKF8($0))</dc:publisher>" } ?? "")
                \(meta.language.map { "<dc:language>\(xmlEscapeKF8($0))</dc:language>" } ?? "<dc:language>en</dc:language>")
                <dc:identifier id="uid">kf8-converted-\(UUID().uuidString)</dc:identifier>
              </metadata>
              <manifest>
            \(manifestItems)  </manifest>
              <spine toc="ncx">
            \(spineItems)  </spine>
            </package>
            """
        try await addTextEntry(archive: archive, path: "OEBPS/content.opf", content: opfXML)

        var navPoints = ""
        if book.parts.count == 1, !book.chapterEntries.isEmpty {
            let filename = book.parts[0].filename
            for (i, entry) in book.chapterEntries.enumerated() {
                let label = xmlEscapeKF8(entry.label)
                navPoints += """
                            <navPoint id="np\(i+1)" playOrder="\(i+1)">
                              <navLabel><text>\(label)</text></navLabel>
                              <content src="Text/\(filename)#\(entry.anchorID)"/>
                            </navPoint>\n
                    """
            }
        } else {
            let partTitles = book.parts.enumerated().map { (i, part) -> String in
                if let titleRange = part.content.range(of: "<title>", options: .caseInsensitive),
                    let endRange = part.content.range(
                        of: "</title>",
                        options: .caseInsensitive,
                        range: titleRange.upperBound..<part.content.endIndex
                    )
                {
                    let title = String(part.content[titleRange.upperBound..<endRange.lowerBound]).trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    if !title.isEmpty { return title }
                }
                return "Part \(i + 1)"
            }

            for (i, part) in book.parts.enumerated() {
                let label = xmlEscapeKF8(partTitles[i])
                navPoints += """
                            <navPoint id="np\(i+1)" playOrder="\(i+1)">
                              <navLabel><text>\(label)</text></navLabel>
                              <content src="Text/\(part.filename)"/>
                            </navPoint>\n
                    """
            }
        }

        let ncxXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
              <head>
                <meta name="dtb:uid" content="kf8-converted"/>
                <meta name="dtb:depth" content="1"/>
              </head>
              <docTitle><text>\(titleEscaped)</text></docTitle>
              <navMap>
            \(navPoints)  </navMap>
            </ncx>
            """
        try await addTextEntry(archive: archive, path: "OEBPS/toc.ncx", content: ncxXML)

        for part in book.parts {
            try Task.checkCancellation()
            try await addTextEntry(archive: archive, path: "OEBPS/Text/\(part.filename)", content: part.content)
        }

        for (i, css) in book.cssFlows.enumerated() {
            try Task.checkCancellation()
            try await addTextEntry(archive: archive, path: "OEBPS/Styles/style\(i).css", content: css)
        }

        for img in book.images {
            try Task.checkCancellation()
            let imgData = img.data
            try await archive.addEntry(
                with: "OEBPS/Images/\(img.name)",
                type: .file,
                uncompressedSize: Int64(imgData.count)
            ) { @Sendable position, size in zipEntryChunk(from: imgData, position: position, size: size) }
        }

        for font in book.fonts {
            try Task.checkCancellation()
            let fontData = font.data
            try await archive.addEntry(
                with: "OEBPS/Fonts/\(font.name)",
                type: .file,
                uncompressedSize: Int64(fontData.count)
            ) { @Sendable position, size in zipEntryChunk(from: fontData, position: position, size: size) }
        }
    }

    private static func addTextEntry(archive: Archive, path: String, content: String) async throws {
        let data = Data(content.utf8)
        try await archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count)
        ) { @Sendable position, size in zipEntryChunk(from: data, position: position, size: size) }
    }

    nonisolated private static func zipEntryChunk(from data: Data, position: Int64, size: Int) -> Data {
        let start = Int(position)
        guard start >= 0, start < data.count, size > 0 else { return Data() }
        let end = min(start + size, data.count)
        return data.subdata(in: start..<end)
    }
}

private func xmlEscapeKF8(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

struct KF8PalmDB {
    let data: Data
    let numRecords: Int
    private let recordOffsets: [Int]

    init(data: Data) throws {
        self.data = data
        guard data.count >= 78 else { throw MobiConversionError.notMobiFile }

        let dbType = data[60..<64]
        let dbCreator = data[64..<68]
        guard dbType == Data([0x42, 0x4F, 0x4F, 0x4B]),
            dbCreator == Data([0x4D, 0x4F, 0x42, 0x49])
        else {
            throw MobiConversionError.notMobiFile
        }

        numRecords = Int(data.readBE16(at: 76))
        guard numRecords > 0 else { throw MobiConversionError.malformed("No records") }

        var offsets: [Int] = []
        for i in 0..<numRecords {
            let entryOffset = 78 + i * 8
            guard entryOffset + 4 <= data.count else {
                throw MobiConversionError.malformed("Record list truncated")
            }
            offsets.append(Int(data.readBE32(at: entryOffset)))
        }
        recordOffsets = offsets
    }

    func record(_ index: Int) throws -> Data {
        guard index < numRecords else {
            throw MobiConversionError.malformed("Record index \(index) out of range")
        }
        let start = recordOffsets[index]
        let end = index + 1 < numRecords ? recordOffsets[index + 1] : data.count
        guard start <= end, end <= data.count else {
            throw MobiConversionError.malformed("Record \(index) out of bounds")
        }
        return Data(data[start..<end])
    }
}

final class KF8HuffcdicDecoder {
    private var dict1: [(codelen: Int, isTerminal: Bool, rawMaxcode: UInt32)] = []
    private var mincode: [UInt64] = Array(repeating: 0, count: 33)
    private var maxcode: [UInt64] = Array(repeating: UInt64.max, count: 33)
    private var dictionary: [(data: Data, decoded: Bool)?] = []

    init(huffRecord: Data, cdicRecords: [Data]) throws {
        guard huffRecord.count >= 24,
            huffRecord[0] == 0x48, huffRecord[1] == 0x55,
            huffRecord[2] == 0x46, huffRecord[3] == 0x46
        else {
            throw MobiConversionError.malformed("Invalid HUFF record")
        }

        let off1 = Int(huffRecord.readBE32(at: 8))
        let off2 = Int(huffRecord.readBE32(at: 12))

        guard off1 + 256 * 4 <= huffRecord.count,
            off2 + 64 * 4 <= huffRecord.count
        else {
            throw MobiConversionError.malformed("HUFF table offsets out of range")
        }

        for i in 0..<256 {
            let v = huffRecord.readBE32(at: off1 + i * 4)
            let codelen = Int(v & 0x1F)
            let isTerminal = (v & 0x80) != 0
            let raw = v >> 8
            guard codelen > 0 else {
                throw MobiConversionError.malformed("HUFF dict1 zero codelen")
            }
            dict1.append((codelen: codelen, isTerminal: isTerminal, rawMaxcode: raw))
        }

        var dict2: [UInt32] = []
        for i in 0..<64 {
            dict2.append(huffRecord.readBE32(at: off2 + i * 4))
        }

        mincode[0] = UInt64.max
        maxcode[0] = 0
        for n in 1...32 {
            let rawMin = UInt64(dict2[(n - 1) * 2])
            let rawMax = UInt64(dict2[(n - 1) * 2 + 1])
            let shift = UInt64(32 - n)
            mincode[n] = rawMin << shift
            maxcode[n] = ((rawMax + 1) << shift) &- 1
        }

        guard let firstCdic = cdicRecords.first,
            firstCdic.count >= 16,
            firstCdic[0] == 0x43, firstCdic[1] == 0x44,
            firstCdic[2] == 0x49, firstCdic[3] == 0x43
        else {
            throw MobiConversionError.malformed("No valid CDIC records")
        }

        let totalPhrases = Int(firstCdic.readBE32(at: 8))
        let bits = Int(firstCdic.readBE32(at: 12))

        for cdic in cdicRecords {
            guard cdic.count >= 16 else { continue }
            let sectionSize = min(1 << bits, totalPhrases - dictionary.count)
            guard sectionSize > 0 else { break }
            for i in 0..<sectionSize {
                let tableOffset = 16 + i * 2
                guard tableOffset + 2 <= cdic.count else { dictionary.append(nil); continue }
                let phraseOffset = Int(cdic.readBE16(at: tableOffset))
                let dataStart = 16 + phraseOffset
                guard dataStart + 2 <= cdic.count else { dictionary.append(nil); continue }
                let blen = cdic.readBE16(at: dataStart)
                let dataLength = Int(blen & 0x7FFF)
                let isDecoded = (blen & 0x8000) != 0
                let dataEnd = dataStart + 2 + dataLength
                guard dataEnd <= cdic.count else { dictionary.append(nil); continue }
                let phraseData = cdic[(dataStart + 2)..<dataEnd]
                dictionary.append((data: Data(phraseData), decoded: isDecoded))
            }
        }
    }

    func decompress(_ compressed: Data) -> Data {
        var output = Data()
        var padded = compressed
        padded.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])

        var pos: Int = 0
        var x: UInt64 = padded.readBE64(at: 0)
        var n: Int = 32
        var bitsleft: Int = compressed.count * 8

        while true {
            if n <= 0 { pos += 4; x = padded.readBE64(at: pos); n += 32 }
            let shift = n < 64 ? n : 63
            let code = UInt32(truncatingIfNeeded: (x >> shift) & 0xFFFF_FFFF)
            let topByte = Int(code >> 24)
            guard topByte < dict1.count else { break }
            let entry = dict1[topByte]
            var codelen = entry.codelen
            var resolvedMax: UInt32
            if entry.isTerminal {
                resolvedMax = ((entry.rawMaxcode + 1) << (32 - codelen)) &- 1
            } else {
                let codeU64 = UInt64(code)
                while codelen <= 32 && codeU64 < mincode[codelen] { codelen += 1 }
                guard codelen <= 32 else { break }
                resolvedMax = UInt32(maxcode[codelen] & 0xFFFF_FFFF)
            }
            n -= codelen; bitsleft -= codelen
            guard bitsleft >= 0 else { break }
            let r = Int((UInt64(resolvedMax) &- UInt64(code)) >> (32 - codelen))
            guard r < dictionary.count, let entry = dictionary[r] else { break }
            let phrase: Data
            if entry.decoded {
                phrase = entry.data
            } else {
                let decompressed = decompress(entry.data)
                dictionary[r] = (data: decompressed, decoded: true)
                phrase = decompressed
            }
            output.append(phrase)
        }
        return output
    }
}

enum KF8PalmDocDecoder {
    static func decompress(_ compressed: Data) -> Data {
        var output = Data()
        output.reserveCapacity(compressed.count * 3)
        var pos = compressed.startIndex
        while pos < compressed.endIndex {
            let c = compressed[pos]; pos = compressed.index(after: pos)
            if c == 0x00 {
                output.append(0x00)
            } else if c <= 0x08 {
                let count = Int(c)
                let end = compressed.index(pos, offsetBy: count, limitedBy: compressed.endIndex) ?? compressed.endIndex
                output.append(contentsOf: compressed[pos..<end]); pos = end
            } else if c < 0x80 {
                output.append(c)
            } else if c >= 0xC0 {
                output.append(0x20); output.append(c ^ 0x80)
            } else {
                guard pos < compressed.endIndex else { break }
                let c2 = compressed[pos]; pos = compressed.index(after: pos)
                let dist = Int((UInt16(c & 0x3F) << 5) | UInt16(c2 >> 3))
                let length = Int(c2 & 0x07) + 3
                guard dist > 0, output.count >= dist else { continue }
                for _ in 0..<length { output.append(output[output.count - dist]) }
            }
        }
        return output
    }
}

extension Data {
    func readBE16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        let base = startIndex + offset
        return UInt16(self[base]) << 8 | UInt16(self[base + 1])
    }
    func readBE32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let base = startIndex + offset
        return UInt32(self[base]) << 24 | UInt32(self[base + 1]) << 16 | UInt32(self[base + 2]) << 8 | UInt32(self[base + 3])
    }
    func readBE64(at offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        let base = startIndex + offset
        return UInt64(self[base]) << 56 | UInt64(self[base + 1]) << 48 | UInt64(self[base + 2]) << 40 | UInt64(self[base + 3]) << 32
            | UInt64(self[base + 4]) << 24 | UInt64(self[base + 5]) << 16 | UInt64(self[base + 6]) << 8 | UInt64(self[base + 7])
    }
}
