import Foundation

/// Decodes the raw EXIF `UserComment` payload (tag 0x9286): an 8-byte character
/// code followed by text. Port of the header/BOM branches of Civitai's
/// `decodeUserComment`; the BOM-less endianness heuristic is deliberately
/// omitted until a real image needs it.
enum ExifUserCommentDecoder {
    static func decode(_ bytes: Data) -> String? {
        guard bytes.count >= 8 else { return nil }
        let header = String(decoding: bytes.prefix(8), as: UTF8.self)
        let body = Data(bytes.dropFirst(8))
        let decoded: String?
        if header.hasPrefix("ASCII") {
            decoded = String(data: body, encoding: .ascii) ?? String(decoding: body, as: UTF8.self)
        } else if header.hasPrefix("UTF8") || header.hasPrefix("UTF-8") {
            decoded = String(decoding: body, as: UTF8.self)
        } else if header.hasPrefix("UNICODE") {
            if body.count >= 2, body[0] == 0xFE, body[1] == 0xFF {
                decoded = String(data: body.dropFirst(2), encoding: .utf16BigEndian)
            } else if body.count >= 2, body[0] == 0xFF, body[1] == 0xFE {
                decoded = String(data: body.dropFirst(2), encoding: .utf16LittleEndian)
            } else {
                decoded = String(data: body, encoding: .utf16BigEndian)
                    ?? String(data: body, encoding: .utf16LittleEndian)
            }
        } else {
            // Undefined / all-zero code: treat as UTF-8 text.
            decoded = String(decoding: body, as: UTF8.self)
        }
        return decoded?.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }
}

/// Finds the raw `UserComment` bytes inside a JPEG's APP1 Exif segment by
/// walking IFD0 → Exif IFD. Only used when ImageIO's decoded string is empty
/// or damaged.
enum JPEGExifScanner {
    static func userCommentBytes(in data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 4 <= b.count, b[i] == 0xFF {
            let marker = b[i + 1]
            if marker == 0xDA || marker == 0xD9 { break } // SOS / EOI: headers are over
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2, i + 2 + length <= b.count else { return nil }
            if marker == 0xE1, length > 8, Array(b[(i + 4)..<(i + 10)]) == Array("Exif\0\0".utf8) {
                return userComment(inTIFF: Array(b[(i + 10)..<(i + 2 + length)]))
            }
            i += 2 + length
        }
        return nil
    }

    private static func userComment(inTIFF t: [UInt8]) -> Data? {
        guard t.count >= 8 else { return nil }
        let little: Bool
        if t[0] == 0x49, t[1] == 0x49 { little = true }
        else if t[0] == 0x4D, t[1] == 0x4D { little = false }
        else { return nil }

        func u16(_ o: Int) -> Int {
            guard o >= 0, o + 2 <= t.count else { return 0 }
            return little ? Int(t[o]) | Int(t[o + 1]) << 8 : Int(t[o]) << 8 | Int(t[o + 1])
        }
        func u32(_ o: Int) -> Int {
            guard o >= 0, o + 4 <= t.count else { return 0 }
            return little
                ? Int(t[o]) | Int(t[o + 1]) << 8 | Int(t[o + 2]) << 16 | Int(t[o + 3]) << 24
                : Int(t[o]) << 24 | Int(t[o + 1]) << 16 | Int(t[o + 2]) << 8 | Int(t[o + 3])
        }
        /// Returns (count, offset of the 4-byte value/offset field) for a tag in an IFD.
        func find(tag: Int, inIFD offset: Int) -> (count: Int, valueField: Int)? {
            guard offset > 0, offset + 2 <= t.count else { return nil }
            let n = u16(offset)
            for k in 0..<n {
                let e = offset + 2 + k * 12
                guard e + 12 <= t.count else { return nil }
                if u16(e) == tag { return (u32(e + 4), e + 8) }
            }
            return nil
        }

        guard let exifPointer = find(tag: 0x8769, inIFD: u32(4)) else { return nil }
        let exifIFD = u32(exifPointer.valueField)
        guard let comment = find(tag: 0x9286, inIFD: exifIFD) else { return nil }
        let start = comment.count <= 4 ? comment.valueField : u32(comment.valueField)
        guard start >= 0, comment.count >= 0, start + comment.count <= t.count else { return nil }
        return Data(t[start..<(start + comment.count)])
    }
}
