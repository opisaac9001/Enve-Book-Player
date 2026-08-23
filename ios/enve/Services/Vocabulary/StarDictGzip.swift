import Compression
import Foundation

enum StarDictGzip {

    static func decompress(_ gz: Data) -> Data? {
        guard gz.count > 10, gz[0] == 0x1f, gz[1] == 0x8b else { return nil }

        guard gz[2] == 0x08 else { return nil }
        let flg = gz[3]
        var offset = 10

        if (flg & 0x04) != 0 {
            guard offset + 2 <= gz.count else { return nil }
            let xlen = Int(gz[offset]) | (Int(gz[offset + 1]) << 8)
            offset += 2 + xlen
            if offset > gz.count { return nil }
        }
        if (flg & 0x08) != 0 {
            while offset < gz.count, gz[offset] != 0 { offset += 1 }
            offset += 1
        }
        if (flg & 0x10) != 0 {
            while offset < gz.count, gz[offset] != 0 { offset += 1 }
            offset += 1
        }
        if (flg & 0x02) != 0 {
            offset += 2
        }
        if offset >= gz.count - 8 { return nil }

        let payload = gz.subdata(in: offset..<(gz.count - 8))
        return inflateRawDeflate(payload)
    }

    private static func inflateRawDeflate(_ deflate: Data) -> Data? {

        var wrapped = Data([0x78, 0x9C])
        wrapped.append(deflate)

        let bufSize = 64 * 1024
        let outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { outBuf.deallocate() }

        var stream = compression_stream(
            dst_ptr: outBuf,
            dst_size: bufSize,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(&stream) }

        var output = Data()
        let success = wrapped.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            stream.src_ptr = base
            stream.src_size = wrapped.count

            repeat {
                stream.dst_ptr = outBuf
                stream.dst_size = bufSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufSize - stream.dst_size
                if produced > 0 {
                    output.append(outBuf, count: produced)
                }
                if status == COMPRESSION_STATUS_END { return true }
                if status == COMPRESSION_STATUS_ERROR { return false }
            } while stream.src_size > 0 || stream.dst_size == 0

            return true
        }

        return success ? output : nil
    }
}
