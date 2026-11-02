import Foundation

/// A string pool of Android's compiled files (ResStringPool): the strings
/// a binary XML document or resources.arsc refers to by index.
struct AndroidStringPool: Sendable {
    let strings: [String]

    /// The pool in the chunk at `offset`; nil when it is not one.
    init?(_ data: Data, at offset: Int) {
        guard data.uint16(at: offset) == 0x0001, let headerSize = data.uint16(at: offset + 2),
              let size = data.uint32(at: offset + 4), let count = data.uint32(at: offset + 8),
              let flags = data.uint32(at: offset + 16), let stringsStart = data.uint32(at: offset + 20),
              Int(count) * 4 <= Int(size) else { return nil }
        let utf8 = flags & 0x100 != 0
        var strings: [String] = []
        for index in 0..<Int(count) {
            guard let relative = data.uint32(at: offset + Int(headerSize) + index * 4) else { return nil }
            let start = offset + Int(stringsStart) + Int(relative)
            strings.append((utf8 ? Self.utf8(data, at: start) : Self.utf16(data, at: start)) ?? "")
        }
        self.strings = strings
    }

    subscript(index: UInt32) -> String? { Int(index) < strings.count ? strings[Int(index)] : nil }

    /// A UTF-16 string: its length in units (one unit, or two when the
    /// first's top bit is set), then the units.
    private static func utf16(_ data: Data, at start: Int) -> String? {
        guard var length = data.uint16(at: start).map(Int.init) else { return nil }
        var position = start + 2
        if length & 0x8000 != 0 {
            guard let low = data.uint16(at: position) else { return nil }
            length = (length & 0x7FFF) << 16 | Int(low)
            position += 2
        }
        guard let bytes = data.bytes(at: position, length: length * 2) else { return nil }
        return String(decoding: (0..<length).compactMap { bytes.uint16(at: $0 * 2) }, as: UTF16.self)
    }

    /// A UTF-8 string: its length in UTF-16 units, then in bytes (each one
    /// byte, or two when the first's top bit is set), then the bytes.
    private static func utf8(_ data: Data, at start: Int) -> String? {
        var position = start
        func length() -> Int? {
            guard let first = data.uint8(at: position) else { return nil }
            position += 1
            guard first & 0x80 != 0 else { return Int(first) }
            guard let second = data.uint8(at: position) else { return nil }
            position += 1
            return Int(first & 0x7F) << 8 | Int(second)
        }
        guard length() != nil, let count = length(), let bytes = data.bytes(at: position, length: count) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}
