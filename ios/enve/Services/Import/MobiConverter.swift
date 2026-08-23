import Foundation
import ReadiumZIPFoundation

enum MobiConversionError: LocalizedError, Equatable {
    case notMobiFile
    case encrypted
    case emptyContent
    case malformed(String)

    static func == (lhs: MobiConversionError, rhs: MobiConversionError) -> Bool {
        switch (lhs, rhs) {
        case (.notMobiFile, .notMobiFile): return true
        case (.encrypted, .encrypted): return true
        case (.emptyContent, .emptyContent): return true
        case (.malformed(let a), .malformed(let b)): return a == b
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .notMobiFile:
            return "File is not a valid MOBI or AZW3 ebook."
        case .encrypted:
            return "This file is DRM-protected and cannot be opened. Use a DRM-free copy."
        case .emptyContent:
            return "No readable content was found in this file."
        case .malformed(let detail):
            return "The file structure is invalid: \(detail)"
        }
    }
}

struct MobiMetadata {
    var title: String
    var author: String?
    var publisher: String?
    var description: String?
    var publishedYear: Int?
    var language: String?
    var coverRecordIndex: UInt32?
}

private struct MobiBook {
    var metadata: MobiMetadata
    var htmlContent: Data
    var images: [(name: String, data: Data)]
    var chapterEntries: [InlineFileposTOCEntry]
    var encoding: String.Encoding
}

enum MobiConverter {

    static func convert(mobiURL: URL, outputURL: URL) async throws {
        try ImportLimits.validateWholeFileRead(mobiURL)
        try Task.checkCancellation()
        let data = try Data(contentsOf: mobiURL)
        try Task.checkCancellation()

        let db = try KF8PalmDB(data: data)
        let record0 = try db.record(0)
        let mobi = try MobiHeader.parse(from: record0)
        guard mobi.encryptionType == 0 else { throw MobiConversionError.encrypted }

        if KF8Reader.isKF8(record0: record0, headerLength: mobi.headerLength) {
            let metadata = try parseMobiMetadata(db: PalmDatabase(data: data))
            let kf8Book = try KF8Reader.parseKF8(
                db: db,
                record0: record0,
                metadata: metadata,
                encoding: mobi.swiftEncoding
            )
            try await KF8Reader.writeEPUB(book: kf8Book, to: outputURL)
            return
        }

        let book = try parseBook(from: data)
        try await writeEpub(book: book, to: outputURL)
    }

    static func extractHTMLForWebKit(mobiURL: URL) async throws -> String {
        try ImportLimits.validateWholeFileRead(mobiURL)
        try Task.checkCancellation()
        let data = try Data(contentsOf: mobiURL)
        try Task.checkCancellation()

        let kf8db = try KF8PalmDB(data: data)
        let rec0 = try kf8db.record(0)
        let mobiHdr = try MobiHeader.parse(from: rec0)
        if KF8Reader.isKF8(record0: rec0, headerLength: mobiHdr.headerLength) {
            let metadata = try parseMobiMetadata(db: PalmDatabase(data: data))
            let kf8Book = try KF8Reader.parseKF8(
                db: kf8db,
                record0: rec0,
                metadata: metadata,
                encoding: mobiHdr.swiftEncoding
            )
            return buildKF8WebKitHTML(kf8Book: kf8Book)
        }

        let book = try parseBook(from: data)

        var html =
            String(data: book.htmlContent, encoding: book.encoding)
            ?? String(data: book.htmlContent, encoding: .isoLatin1)
            ?? ""

        if let xmlDeclRegex = try? NSRegularExpression(pattern: "^\\s*<\\?xml[^?]*\\?>\\s*", options: .caseInsensitive) {
            let range = NSRange(html.startIndex..., in: html)
            html = xmlDeclRegex.stringByReplacingMatches(in: html, range: range, withTemplate: "")
        }
        if let doctypeRegex = try? NSRegularExpression(pattern: "^\\s*<!DOCTYPE[^>]*>\\s*", options: .caseInsensitive) {
            let range = NSRange(html.startIndex..., in: html)
            html = doctypeRegex.stringByReplacingMatches(in: html, range: range, withTemplate: "")
        }

        if let closeRange = html.range(of: "</html>", options: [.caseInsensitive, .backwards]) {
            html = String(html[html.startIndex...closeRange.upperBound].dropLast()) + "</html>"
        }

        for (idx, img) in book.images.enumerated() {
            let recIndex = idx + 1
            let b64 = img.data.base64EncodedString()
            let ext = String(img.name.split(separator: ".").last ?? "jpg")
            let mime = ext == "png" ? "image/png" : (ext == "gif" ? "image/gif" : "image/jpeg")
            let dataURL = "data:\(mime);base64,\(b64)"
            let padded = String(format: "%05d", recIndex)
            html = html.replacingOccurrences(of: "recindex=\"\(padded)\"", with: "src=\"\(dataURL)\"")
            html = html.replacingOccurrences(of: "recindex=\"\(recIndex)\"", with: "src=\"\(dataURL)\"")
        }

        let injected = """
            <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=3">
            <style>
            body{font-family:-apple-system,sans-serif;padding:16px;max-width:720px;margin:0 auto;line-height:1.6;word-wrap:break-word;}
            img{max-width:100%;height:auto;}
            </style>
            """
        if html.lowercased().contains("</head>") {
            html = html.replacingOccurrences(of: "</head>", with: "\(injected)\n</head>", options: .caseInsensitive)
        } else {
            html = "<html><head>\(injected)</head><body>\(html)</body></html>"
        }

        return html
    }

    private static func buildKF8WebKitHTML(kf8Book: KF8Book) -> String {

        let cssBlock = kf8Book.cssFlows.map { "<style>\($0)</style>" }.joined(separator: "\n")

        var imageMap: [String: String] = [:]
        for (i, img) in kf8Book.images.enumerated() {
            let ext = String(img.name.split(separator: ".").last ?? "jpg")
            let mime = ext == "png" ? "image/png" : (ext == "gif" ? "image/gif" : "image/jpeg")
            let dataURL = "data:\(mime);base64,\(img.data.base64EncodedString())"
            imageMap["../Images/\(img.name)"] = dataURL
            imageMap["Images/\(img.name)"] = dataURL

            let padded = String(format: "%05d", i + 1)
            imageMap[padded] = dataURL
        }

        var bodies: [String] = []
        for part in kf8Book.parts {
            var content = part.content

            if let bodyStart = content.range(of: "<body", options: .caseInsensitive) {
                if let bodyTagEnd = content.range(of: ">", range: bodyStart.upperBound..<content.endIndex) {
                    let afterBody = content[bodyTagEnd.upperBound...]
                    if let bodyEnd = afterBody.range(of: "</body>", options: .caseInsensitive) {
                        content = String(afterBody[..<bodyEnd.lowerBound])
                    } else {
                        content = String(afterBody)
                    }
                }
            }
            bodies.append(content)
        }

        var html = bodies.joined(separator: "\n<hr style=\"page-break-after:always;\"/>\n")

        for (ref, dataURL) in imageMap {
            html = html.replacingOccurrences(of: "src=\"\(ref)\"", with: "src=\"\(dataURL)\"")
            html = html.replacingOccurrences(of: "href=\"\(ref)\"", with: "href=\"\(dataURL)\"")
        }

        let injected = """
            <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=3">
            <style>
            body{font-family:-apple-system,sans-serif;padding:16px;max-width:720px;margin:0 auto;line-height:1.6;word-wrap:break-word;}
            img{max-width:100%;height:auto;}
            </style>
            """

        return "<html><head>\(injected)\(cssBlock)</head><body>\(html)</body></html>"
    }

    static func extractMetadata(from mobiURL: URL) throws -> MobiMetadata {
        try ImportLimits.validateWholeFileRead(mobiURL)
        try Task.checkCancellation()
        let data = try Data(contentsOf: mobiURL)
        try Task.checkCancellation()
        let db = try PalmDatabase(data: data)
        return try parseMobiMetadata(db: db)
    }
}

private struct PalmDatabase {
    let data: Data
    let numRecords: Int
    private let recordOffsets: [Int]

    static let mobiCreator = Data([0x4D, 0x4F, 0x42, 0x49])
    static let bookType = Data([0x42, 0x4F, 0x4F, 0x4B])

    init(data: Data) throws {
        self.data = data
        guard data.count >= 78 else { throw MobiConversionError.notMobiFile }

        let dbType = data[60..<64]
        let dbCreator = data[64..<68]
        guard dbType == Data(PalmDatabase.bookType) && dbCreator == Data(PalmDatabase.mobiCreator) else {
            throw MobiConversionError.notMobiFile
        }

        numRecords = Int(data.readBigEndianUInt16(at: 76))
        guard numRecords > 0 else { throw MobiConversionError.malformed("No records") }

        var offsets: [Int] = []
        for i in 0..<numRecords {
            let entryOffset = 78 + i * 8
            guard entryOffset + 4 <= data.count else {
                throw MobiConversionError.malformed("Record list truncated")
            }
            offsets.append(Int(data.readBigEndianUInt32(at: entryOffset)))
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

private struct MobiHeader {
    let compression: UInt16
    let uncompressedLength: UInt32
    let textRecordCount: UInt16
    let encryptionType: UInt16
    let bookType: UInt32
    let encoding: UInt32
    let headerLength: UInt32

    let firstNonBookRecord: UInt32
    let titleOffset: UInt32
    let titleLength: UInt32
    let firstImageRecord: UInt32
    let huffmanRecordOffset: UInt32
    let huffmanRecordCount: UInt32
    let exthFlags: UInt32

    static func parse(from record0: Data) throws -> MobiHeader {
        guard record0.count >= 32 else {
            throw MobiConversionError.malformed("Record0 too small")
        }

        let compression = record0.readBigEndianUInt16(at: 0)
        let uncompressed = record0.readBigEndianUInt32(at: 4)
        let textCount = record0.readBigEndianUInt16(at: 8)
        let encryption = record0.readBigEndianUInt16(at: 12)

        guard record0.count >= 20,
            record0[16] == 0x4D, record0[17] == 0x4F,
            record0[18] == 0x42, record0[19] == 0x49
        else {
            throw MobiConversionError.malformed("Missing MOBI identifier")
        }

        let headerLength = record0.readBigEndianUInt32(at: 20)
        let bookType = record0.readBigEndianUInt32(at: 24)
        let encoding = record0.readBigEndianUInt32(at: 28)

        let mobi = 16

        func field(_ offsetFromMobi: Int) -> UInt32 {
            let abs = mobi + offsetFromMobi
            guard abs + 4 <= record0.count else { return 0xFFFF_FFFF }
            return record0.readBigEndianUInt32(at: abs)
        }

        return MobiHeader(
            compression: compression,
            uncompressedLength: uncompressed,
            textRecordCount: textCount,
            encryptionType: encryption,
            bookType: bookType,
            encoding: encoding,
            headerLength: headerLength,
            firstNonBookRecord: field(64),
            titleOffset: field(68),
            titleLength: field(72),
            firstImageRecord: field(92),
            huffmanRecordOffset: field(96),
            huffmanRecordCount: field(100),
            exthFlags: field(112)
        )
    }

    var isKF8: Bool { bookType == 258 }
    var isHuffman: Bool { compression == 17480 }
    var isPalmDOC: Bool { compression == 2 }
    var isUncompressed: Bool { compression == 1 }
    var hasEXTH: Bool { exthFlags & 0x40 != 0 }

    var swiftEncoding: String.Encoding {
        switch encoding {
        case 65001: return .utf8
        case 1252: return .windowsCP1252
        default: return .utf8
        }
    }
}

private struct ExthSection {
    struct Record {
        let type: UInt32
        let data: Data
    }
    let records: [Record]

    static func parse(from record0: Data, mobi: MobiHeader) -> ExthSection? {
        guard mobi.hasEXTH else { return nil }
        let exthStart = 16 + Int(mobi.headerLength)
        guard exthStart + 12 <= record0.count else { return nil }
        guard record0[exthStart] == 0x45,
            record0[exthStart + 1] == 0x58,
            record0[exthStart + 2] == 0x54,
            record0[exthStart + 3] == 0x48
        else { return nil }

        let sectionLength = Int(record0.readBigEndianUInt32(at: exthStart + 4))
        let recordCount = Int(record0.readBigEndianUInt32(at: exthStart + 8))

        var records: [Record] = []
        var pos = exthStart + 12
        let sectionEnd = exthStart + sectionLength

        for _ in 0..<recordCount {
            guard pos + 8 <= min(sectionEnd, record0.count) else { break }
            let type = record0.readBigEndianUInt32(at: pos)
            let length = Int(record0.readBigEndianUInt32(at: pos + 4))
            guard length >= 8, pos + length <= record0.count else { break }
            let payload = record0[(pos + 8)..<(pos + length)]
            records.append(Record(type: type, data: Data(payload)))
            pos += length
        }
        return ExthSection(records: records)
    }

    func string(forType type: UInt32, encoding: String.Encoding = .utf8) -> String? {
        records.first(where: { $0.type == type }).flatMap {
            String(data: $0.data, encoding: encoding) ?? String(data: $0.data, encoding: .isoLatin1)
        }
    }

    func uint32(forType type: UInt32) -> UInt32? {
        guard let r = records.first(where: { $0.type == type }),
            r.data.count >= 4
        else { return nil }
        return r.data.readBigEndianUInt32(at: 0)
    }
}

private enum PalmDocDecoder {
    static func decompress(_ compressed: Data) -> Data {
        var output = Data()
        output.reserveCapacity(compressed.count * 3)
        var pos = compressed.startIndex

        while pos < compressed.endIndex {
            let c = compressed[pos]
            pos = compressed.index(after: pos)

            if c == 0x00 {
                output.append(0x00)
            } else if c <= 0x08 {
                let count = Int(c)
                let end = compressed.index(pos, offsetBy: count, limitedBy: compressed.endIndex) ?? compressed.endIndex
                output.append(contentsOf: compressed[pos..<end])
                pos = end
            } else if c < 0x80 {
                output.append(c)
            } else if c >= 0xC0 {
                output.append(0x20)
                output.append(c ^ 0x80)
            } else {

                guard pos < compressed.endIndex else { break }
                let c2 = compressed[pos]
                pos = compressed.index(after: pos)
                let dist = Int((UInt16(c & 0x3F) << 5) | UInt16(c2 >> 3))
                let length = Int(c2 & 0x07) + 3
                guard dist > 0, output.count >= dist else { continue }
                for _ in 0..<length {
                    output.append(output[output.count - dist])
                }
            }
        }
        return output
    }
}

private final class HuffcdicDecoder {

    private var dict1: [(codelen: Int, isTerminal: Bool, rawMaxcode: UInt32)] = []

    private var mincode: [UInt64] = Array(repeating: 0, count: 33)
    private var maxcode: [UInt64] = Array(repeating: UInt64.max, count: 33)

    private var dictionary: [(data: Data, decoded: Bool)?] = []
    private let bitsPerSection: Int

    init(huffRecord: Data, cdicRecords: [Data]) throws {
        guard huffRecord.count >= 24,
            huffRecord[0] == 0x48, huffRecord[1] == 0x55,
            huffRecord[2] == 0x46, huffRecord[3] == 0x46
        else {
            throw MobiConversionError.malformed("Invalid HUFF record magic")
        }

        let off1 = Int(huffRecord.readBigEndianUInt32(at: 8))
        let off2 = Int(huffRecord.readBigEndianUInt32(at: 12))

        guard off1 + 256 * 4 <= huffRecord.count,
            off2 + 64 * 4 <= huffRecord.count
        else {
            throw MobiConversionError.malformed("HUFF table offsets out of range")
        }

        for i in 0..<256 {
            let v = huffRecord.readBigEndianUInt32(at: off1 + i * 4)
            let codelen = Int(v & 0x1F)
            let isTerminal = (v & 0x80) != 0
            let rawMaxcode = v >> 8
            guard codelen > 0 else {
                throw MobiConversionError.malformed("HUFF dict1 entry has zero codelen")
            }
            dict1.append((codelen: codelen, isTerminal: isTerminal, rawMaxcode: rawMaxcode))
        }

        var dict2: [UInt32] = []
        for i in 0..<64 {
            dict2.append(huffRecord.readBigEndianUInt32(at: off2 + i * 4))
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

        let totalPhrases = Int(firstCdic.readBigEndianUInt32(at: 8))
        let bits = Int(firstCdic.readBigEndianUInt32(at: 12))
        bitsPerSection = bits

        for cdic in cdicRecords {
            guard cdic.count >= 16 else { continue }
            let sectionSize = min(1 << bits, totalPhrases - dictionary.count)
            guard sectionSize > 0 else { break }

            for i in 0..<sectionSize {
                let tableOffset = 16 + i * 2
                guard tableOffset + 2 <= cdic.count else {
                    dictionary.append(nil)
                    continue
                }
                let phraseOffset = Int(cdic.readBigEndianUInt16(at: tableOffset))
                let dataStart = 16 + phraseOffset
                guard dataStart + 2 <= cdic.count else {
                    dictionary.append(nil)
                    continue
                }
                let blen = cdic.readBigEndianUInt16(at: dataStart)
                let dataLength = Int(blen & 0x7FFF)
                let isDecoded = (blen & 0x8000) != 0
                let dataEnd = dataStart + 2 + dataLength
                guard dataEnd <= cdic.count else {
                    dictionary.append(nil)
                    continue
                }
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
        var x: UInt64 = padded.readBigEndianUInt64(at: 0)
        var n: Int = 32
        var bitsleft: Int = compressed.count * 8

        while true {
            if n <= 0 {
                pos += 4
                x = padded.readBigEndianUInt64(at: pos)
                n += 32
            }

            let shift = n < 64 ? n : 63
            let code = UInt32(truncatingIfNeeded: (x >> shift) & 0xFFFF_FFFF)
            let topByte = Int(code >> 24)

            guard topByte < dict1.count else { break }
            let entry = dict1[topByte]
            var codelen = entry.codelen
            var resolvedMaxcode: UInt32

            if entry.isTerminal {
                resolvedMaxcode = ((entry.rawMaxcode + 1) << (32 - codelen)) &- 1
            } else {
                let codeU64 = UInt64(code)
                while codelen <= 32 && codeU64 < mincode[codelen] {
                    codelen += 1
                }
                guard codelen <= 32 else { break }
                resolvedMaxcode = UInt32(maxcode[codelen] & 0xFFFF_FFFF)
            }

            n -= codelen
            bitsleft -= codelen
            guard bitsleft >= 0 else { break }

            let r = Int((UInt64(resolvedMaxcode) &- UInt64(code)) >> (32 - codelen))
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

private func parseMobiMetadata(db: PalmDatabase) throws -> MobiMetadata {
    let record0 = try db.record(0)
    let mobi = try MobiHeader.parse(from: record0)
    let exth = ExthSection.parse(from: record0, mobi: mobi)
    let enc = mobi.swiftEncoding

    let fullTitle: String? = {
        let off = Int(mobi.titleOffset)
        let len = Int(mobi.titleLength)
        guard off > 0, len > 0, off + len <= record0.count else { return nil }
        return String(data: record0[off..<(off + len)], encoding: enc)
    }()

    let palmTitle: String? = {
        guard record0.count >= 32 else { return nil }
        let raw = record0[0..<32]
        let end = raw.firstIndex(of: 0) ?? raw.endIndex
        return String(data: raw[..<end], encoding: .utf8)
    }()

    let title = fullTitle ?? palmTitle ?? exth?.string(forType: 503, encoding: enc) ?? "Unknown"
    let author = exth?.string(forType: 100, encoding: enc)
    let publisher = exth?.string(forType: 101, encoding: enc)
    let desc = exth?.string(forType: 106, encoding: enc)
    let language = exth?.string(forType: 524, encoding: enc)
    let coverIdx = exth?.uint32(forType: 201)

    var year: Int?
    if let pubDate = exth?.string(forType: 106, encoding: enc),
        let y = Int(pubDate.prefix(4))
    {
        year = y
    }

    return MobiMetadata(
        title: title,
        author: author,
        publisher: publisher,
        description: desc,
        publishedYear: year,
        language: language,
        coverRecordIndex: coverIdx
    )
}

private func parseBook(from data: Data) throws -> MobiBook {
    let db = try PalmDatabase(data: data)
    let record0 = try db.record(0)
    let mobi = try MobiHeader.parse(from: record0)

    guard mobi.encryptionType == 0 else {
        throw MobiConversionError.encrypted
    }

    let enc = mobi.swiftEncoding
    let metadata = try parseMobiMetadata(db: db)

    let textCount = Int(mobi.textRecordCount)
    guard textCount > 0 else {
        throw MobiConversionError.malformed("No text records (textRecordCount=0)")
    }
    let firstText = 1
    let lastText = firstText + textCount - 1
    guard lastText < db.numRecords else {
        throw MobiConversionError.malformed("Text records extend beyond file")
    }

    var rawHTML = Data()
    rawHTML.reserveCapacity(Int(mobi.uncompressedLength))

    if mobi.isHuffman {

        let huffIdx = Int(mobi.huffmanRecordOffset)
        let huffCount = Int(mobi.huffmanRecordCount)
        guard huffIdx > 0, huffIdx + huffCount <= db.numRecords else {
            throw MobiConversionError.malformed("Huffman record index out of range")
        }
        let huffRecord = try db.record(huffIdx)
        var cdicRecords: [Data] = []
        for i in (huffIdx + 1)..<(huffIdx + huffCount) {
            cdicRecords.append(try db.record(i))
        }
        let decoder = try HuffcdicDecoder(huffRecord: huffRecord, cdicRecords: cdicRecords)
        for i in firstText...lastText {
            let rec = try db.record(i)
            rawHTML.append(decoder.decompress(rec))
        }
    } else if mobi.isPalmDOC {
        for i in firstText...lastText {
            rawHTML.append(PalmDocDecoder.decompress(try db.record(i)))
        }
    } else if mobi.isUncompressed {
        for i in firstText...lastText {
            rawHTML.append(try db.record(i))
        }
    } else {
        throw MobiConversionError.malformed("Unknown compression type \(mobi.compression)")
    }

    guard !rawHTML.isEmpty else {
        throw MobiConversionError.emptyContent
    }

    var images: [(name: String, data: Data)] = []
    let firstImg = Int(mobi.firstImageRecord)
    let firstNon = Int(mobi.firstNonBookRecord)

    if firstImg > 0, firstImg < db.numRecords {
        let imgEnd = firstNon < db.numRecords ? firstNon : db.numRecords
        for i in firstImg..<max(firstImg, imgEnd) {
            guard let imgData = try? db.record(i), !imgData.isEmpty else { continue }
            if let ext = imageFileExtension(for: imgData) {
                let idx = i - firstImg
                images.append((name: "image\(String(format: "%04d", idx)).\(ext)", data: imgData))
            }
        }
    }

    return MobiBook(
        metadata: metadata,
        htmlContent: rawHTML,
        images: images,
        chapterEntries: InlineFileposTOCHelper.parseEntries(from: rawHTML, encoding: enc),
        encoding: enc
    )
}

private func imageFileExtension(for data: Data) -> String? {
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

private func writeEpub(book: MobiBook, to outputURL: URL) async throws {
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
    let containerData = Data(containerXML.utf8)
    try await archive.addEntry(
        with: "META-INF/container.xml",
        type: .file,
        uncompressedSize: Int64(containerData.count)
    ) { @Sendable position, size in zipEntryChunk(from: containerData, position: position, size: size) }

    let imageManifestItems = book.images.enumerated().map { idx, img in
        let mediaType: String
        switch img.name.split(separator: ".").last ?? "" {
        case "jpg": mediaType = "image/jpeg"
        case "png": mediaType = "image/png"
        case "gif": mediaType = "image/gif"
        case "webp": mediaType = "image/webp"
        default: mediaType = "image/jpeg"
        }
        return """
                <item id="img\(idx)" href="Images/\(img.name)" media-type="\(mediaType)"/>
            """
    }.joined(separator: "\n    ")

    let titleEscaped = xmlEscape(meta.title)
    let authorEscaped = xmlEscape(meta.author ?? "Unknown Author")
    let descEscaped = xmlEscape(meta.description ?? "")

    let opfXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
            <dc:title>\(titleEscaped)</dc:title>
            <dc:creator opf:role="aut">\(authorEscaped)</dc:creator>
            \(meta.publisher.map { "<dc:publisher>\(xmlEscape($0))</dc:publisher>" } ?? "")
            \(descEscaped.isEmpty ? "" : "<dc:description>\(descEscaped)</dc:description>")
            \(meta.language.map { "<dc:language>\(xmlEscape($0))</dc:language>" } ?? "<dc:language>en</dc:language>")
            <dc:identifier id="uid">mobi-converted</dc:identifier>
          </metadata>
          <manifest>
            <item id="content" href="Text/content.html" media-type="text/html"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            \(imageManifestItems)
          </manifest>
          <spine toc="ncx">
            <itemref idref="content"/>
          </spine>
        </package>
        """
    let opfData = Data(opfXML.utf8)
    try await archive.addEntry(
        with: "OEBPS/content.opf",
        type: .file,
        uncompressedSize: Int64(opfData.count)
    ) { @Sendable position, size in zipEntryChunk(from: opfData, position: position, size: size) }

    let navPoints: String = {
        if !book.chapterEntries.isEmpty {
            return book.chapterEntries.enumerated().map { index, entry in
                """
                    <navPoint id="np\(index + 1)" playOrder="\(index + 1)">
                      <navLabel><text>\(xmlEscape(entry.label))</text></navLabel>
                      <content src="Text/content.html#\(entry.anchorID)"/>
                    </navPoint>
                """
            }.joined(separator: "\n")
        }

        return """
                <navPoint id="np1" playOrder="1">
                  <navLabel><text>\(titleEscaped)</text></navLabel>
                  <content src="Text/content.html"/>
                </navPoint>
            """
    }()

    let ncxXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head>
            <meta name="dtb:uid" content="mobi-converted"/>
            <meta name="dtb:depth" content="1"/>
          </head>
          <docTitle><text>\(titleEscaped)</text></docTitle>
          <navMap>
        \(navPoints)
          </navMap>
        </ncx>
        """
    let ncxData = Data(ncxXML.utf8)
    try await archive.addEntry(
        with: "OEBPS/toc.ncx",
        type: .file,
        uncompressedSize: Int64(ncxData.count)
    ) { @Sendable position, size in zipEntryChunk(from: ncxData, position: position, size: size) }

    let htmlContent = normalizeToHTML(
        book.htmlContent,
        encoding: book.encoding,
        title: meta.title,
        chapterEntries: book.chapterEntries
    )
    let htmlData = Data(htmlContent.utf8)
    try await archive.addEntry(
        with: "OEBPS/Text/content.html",
        type: .file,
        uncompressedSize: Int64(htmlData.count)
    ) { @Sendable position, size in zipEntryChunk(from: htmlData, position: position, size: size) }

    for img in book.images {
        let imgData = img.data
        try await archive.addEntry(
            with: "OEBPS/Images/\(img.name)",
            type: .file,
            uncompressedSize: Int64(imgData.count)
        ) { @Sendable position, size in zipEntryChunk(from: imgData, position: position, size: size) }
    }
}

nonisolated private func zipEntryChunk(from data: Data, position: Int64, size: Int) -> Data {
    let start = Int(position)
    guard start >= 0, start < data.count, size > 0 else { return Data() }
    let end = min(start + size, data.count)
    return data.subdata(in: start..<end)
}

private func normalizeToHTML(
    _ data: Data,
    encoding: String.Encoding,
    title: String,
    chapterEntries: [InlineFileposTOCEntry] = []
) -> String {
    var raw =
        String(data: data, encoding: encoding)
        ?? String(data: data, encoding: .isoLatin1)
        ?? ""

    raw = InlineFileposTOCHelper.injectAnchorsAndRewriteLinks(in: raw, entries: chapterEntries)

    if let mbpRegex = try? NSRegularExpression(pattern: "</?mbp:[^>]*>", options: .caseInsensitive) {
        let range = NSRange(raw.startIndex..., in: raw)
        raw = mbpRegex.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
    }

    if let xmlDeclRegex = try? NSRegularExpression(pattern: "<\\?xml[^?]*\\?>", options: .caseInsensitive) {
        let range = NSRange(raw.startIndex..., in: raw)
        raw = xmlDeclRegex.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
    }
    if let doctypeRegex = try? NSRegularExpression(pattern: "<!DOCTYPE[^>]*>", options: .caseInsensitive) {
        let range = NSRange(raw.startIndex..., in: raw)
        raw = doctypeRegex.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
    }

    raw = raw.replacingOccurrences(
        of: " xmlns=\"http://www.w3.org/1999/xhtml\"",
        with: "",
        options: .caseInsensitive
    )

    if let closeRange = raw.range(of: "</html>", options: [.caseInsensitive, .backwards]) {
        raw = String(raw[..<closeRange.upperBound])
    }

    let lower = raw.lowercased()
    if lower.contains("<html") {
        return "<!DOCTYPE html>\n" + ensureUTF8Head(in: raw, title: title)
    }

    return """
        <!DOCTYPE html>
        <html>
          <head>
            <meta charset="utf-8"/>
            <title>\(xmlEscape(title))</title>
          </head>
          <body>
        \(raw)
          </body>
        </html>
        """
}

private func ensureUTF8Head(in html: String, title: String) -> String {
    var html = html
    let hasCharset =
        html.range(
            of: #"<meta\s+charset\s*=\s*["'][^"']+["']\s*/?>"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    let hasTitle = html.range(of: #"<title\b[^>]*>.*?</title>"#, options: [.regularExpression, .caseInsensitive]) != nil
    let headInsertions = (hasCharset ? "" : "<meta charset=\"utf-8\"/>") + (hasTitle ? "" : "<title>\(xmlEscape(title))</title>")

    guard !headInsertions.isEmpty else { return html }

    if let headClose = html.range(of: "</head>", options: .caseInsensitive) {
        html.insert(contentsOf: headInsertions, at: headClose.lowerBound)
        return html
    }

    if let htmlOpen = html.range(of: #"<html\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
        html.insert(contentsOf: "<head>\(headInsertions)</head>", at: htmlOpen.upperBound)
        return html
    }

    return """
        <html>
          <head>\(headInsertions)</head>
          <body>\(html)</body>
        </html>
        """
}

private func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

private extension Data {
    func readBigEndianUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        let base = startIndex + offset
        return UInt16(self[base]) << 8 | UInt16(self[base + 1])
    }

    func readBigEndianUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let base = startIndex + offset
        return UInt32(self[base]) << 24
            | UInt32(self[base + 1]) << 16
            | UInt32(self[base + 2]) << 8
            | UInt32(self[base + 3])
    }

    func readBigEndianUInt64(at offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        let base = startIndex + offset
        return UInt64(self[base]) << 56
            | UInt64(self[base + 1]) << 48
            | UInt64(self[base + 2]) << 40
            | UInt64(self[base + 3]) << 32
            | UInt64(self[base + 4]) << 24
            | UInt64(self[base + 5]) << 16
            | UInt64(self[base + 6]) << 8
            | UInt64(self[base + 7])
    }
}
