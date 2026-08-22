//
//  Data+Extensions.swift
//  StoryAlign
//
//  Created by Rich Waters on 2/28/26.
//


import Foundation
import zlib

import Foundation
import zlib

extension Data {
    func gzipped(level: Int32 = Z_DEFAULT_COMPRESSION) throws -> Data {
        guard !isEmpty else { return self }

        var stream = z_stream()
        let windowBits:Int32 = 15 + 16 // gzip wrapper
        let memLevel: Int32 = 8
        let strategy: Int32 = Z_DEFAULT_STRATEGY

        let initRC = deflateInit2_(
            &stream,
            level,
            Z_DEFLATED,
            windowBits,
            memLevel,
            strategy,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initRC == Z_OK else {
            throw NSError(domain: "gzip", code: Int(initRC))
        }
        defer { deflateEnd(&stream) }

        var output = Data()
        let chunkSize = 64 * 1024
        var buffer = Data(count: chunkSize)

        try self.withUnsafeBytes { srcRaw in
            guard let srcBase = srcRaw.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            stream.next_in = UnsafeMutablePointer<UInt8>(mutating: srcBase)
            stream.avail_in = uInt(self.count)

            while true {
                let produced: Int = buffer.withUnsafeMutableBytes { dstRaw in
                    let dstBase = dstRaw.bindMemory(to: UInt8.self).baseAddress!
                    stream.next_out = dstBase
                    stream.avail_out = uInt(chunkSize)

                    let status = deflate(&stream, Z_FINISH)
                    let outCount = chunkSize - Int(stream.avail_out)

                    if status == Z_STREAM_END {
                        return outCount
                    }
                    if status != Z_OK {
                        // propagate error by storing a sentinel and checking after
                        stream.msg = UnsafeMutablePointer(mutating: ("deflate failed" as NSString).utf8String)
                        return -outCount - 1
                    }
                    return outCount
                }

                if produced < 0 {
                    throw NSError(domain: "gzip", code: 2)
                }
                if produced > 0 {
                    output.append(buffer.prefix(produced))
                }

                // When input is exhausted, Z_STREAM_END will have been returned
                if stream.avail_out != 0 {
                    // If we didn’t fill the output buffer, we’re done.
                    break
                }
            }
        }

        return output
    }

    func gunzipped() throws -> Data {
        guard !isEmpty else { return self }

        var stream = z_stream()
        let windowBits:Int32 = 15 + 32 // auto-detect gzip/zlib header

        let initRC = inflateInit2_(
            &stream,
            windowBits,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initRC == Z_OK else {
            throw NSError(domain: "gunzip", code: Int(initRC))
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = 64 * 1024
        var buffer = Data(count: chunkSize)

        try self.withUnsafeBytes { srcRaw in
            guard let srcBase = srcRaw.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            stream.next_in = UnsafeMutablePointer<UInt8>(mutating: srcBase)
            stream.avail_in = uInt(self.count)

            while true {
                let (status, produced) = buffer.withUnsafeMutableBytes { dstRaw -> (Int32, Int) in
                    let dstBase = dstRaw.bindMemory(to: UInt8.self).baseAddress!
                    stream.next_out = dstBase
                    stream.avail_out = uInt(chunkSize)

                    let st = inflate(&stream, Z_NO_FLUSH)
                    let outCount = chunkSize - Int(stream.avail_out)
                    return (st, outCount)
                }

                if produced > 0 {
                    output.append(buffer.prefix(produced))
                }

                if status == Z_STREAM_END {
                    break
                }
                if status != Z_OK {
                    throw NSError(domain: "gunzip", code: Int(status))
                }
                if stream.avail_in == 0 && produced == 0 {
                    // No input left and no progress — avoid infinite loop on corrupt data.
                    throw NSError(domain: "gunzip", code: 3)
                }
            }
        }

        return output
    }
}
