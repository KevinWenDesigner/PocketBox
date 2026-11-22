import Compression
import Foundation

enum GzipDecoder {
    /// Decompresses RFC 1952 gzip data if the `1f 8b` magic header is present; otherwise returns input unchanged.
    static func decompressIfNeeded(_ data: Data) -> Data {
        guard data.count > 18, data[0] == 0x1F, data[1] == 0x8B, data[2] == 0x08 else {
            return data
        }

        let flags = data[3]
        var cursor = 10

        // FEXTRA (bit 2)
        if (flags & 0x04) != 0 {
            guard cursor + 2 <= data.count else { return data }
            let xlen = Int(data[cursor]) | (Int(data[cursor + 1]) << 8)
            cursor += 2 + xlen
        }

        // FNAME (bit 3)
        if (flags & 0x08) != 0 {
            while cursor < data.count && data[cursor] != 0 {
                cursor += 1
            }
            cursor += 1
        }

        // FCOMMENT (bit 4)
        if (flags & 0x10) != 0 {
            while cursor < data.count && data[cursor] != 0 {
                cursor += 1
            }
            cursor += 1
        }

        // FHCRC (bit 1)
        if (flags & 0x02) != 0 {
            cursor += 2
        }

        let trailerLength = 8
        guard cursor < data.count - trailerLength else {
            return data
        }

        let deflatePayload = data.subdata(in: cursor..<(data.count - trailerLength))
        return inflateRawDeflate(deflatePayload) ?? data
    }

    private static func inflateRawDeflate(_ payload: Data) -> Data? {
        guard !payload.isEmpty else { return nil }

        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }

        var status = compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard status != COMPRESSION_STATUS_ERROR else { return nil }
        defer { compression_stream_destroy(streamPointer) }

        let bufferSize = 65_536
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { dstBuffer.deallocate() }

        return payload.withUnsafeBytes { rawBuffer -> Data? in
            guard let srcBase = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            streamPointer.pointee.src_ptr = srcBase
            streamPointer.pointee.src_size = payload.count

            var output = Data()
            repeat {
                streamPointer.pointee.dst_ptr = dstBuffer
                streamPointer.pointee.dst_size = bufferSize

                status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - streamPointer.pointee.dst_size
                if produced > 0 {
                    output.append(dstBuffer, count: produced)
                }

                if status == COMPRESSION_STATUS_ERROR {
                    return nil
                }
                if produced == 0 && status == COMPRESSION_STATUS_OK {
                    break
                }
            } while status == COMPRESSION_STATUS_OK

            return output.isEmpty ? nil : output
        }
    }
}
