import Foundation

/// The UUID the linker gives an executable (its LC_UUID load command):
/// what tells one build of an app from another when their version numbers
/// are the same. The server reads it from a published .ipa; an app reads
/// its own, to say which build is installed.
public enum MachOUUID {
    /// The UUID in an executable's bytes — thin, or fat (the arm64 slice,
    /// else the first) — or nil when it is not a Mach-O or has none.
    public static func uuid(in data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { return nil }
        let magic = UInt32(bigEndian: bytes, at: 0)
        if magic == 0xCAFE_BABE || magic == 0xCAFE_BABF {
            guard let offset = fatSliceOffset(bytes, wide: magic == 0xCAFE_BABF) else { return nil }
            return thinUUID(bytes, at: offset)
        }
        return thinUUID(bytes, at: 0)
    }

    /// An executable file's UUID, reading only its headers.
    public static func uuid(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: headerBytes), head.count >= 8 else { return nil }
        let bytes = [UInt8](head)
        let magic = UInt32(bigEndian: bytes, at: 0)
        guard magic == 0xCAFE_BABE || magic == 0xCAFE_BABF else { return uuid(in: head) }
        guard let offset = fatSliceOffset(bytes, wide: magic == 0xCAFE_BABF),
              (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let slice = try? handle.read(upToCount: headerBytes) else { return nil }
        return thinUUID([UInt8](slice), at: 0)
    }

    /// Enough of an executable to hold its header and load commands.
    private static let headerBytes = 256 * 1024

    private static func fatSliceOffset(_ bytes: [UInt8], wide: Bool) -> Int? {
        let count = Int(UInt32(bigEndian: bytes, at: 4))
        let entry = wide ? 32 : 20
        var first: Int?
        for index in 0..<count {
            let base = 8 + index * entry
            guard base + entry <= bytes.count else { break }
            let cpu = UInt32(bigEndian: bytes, at: base)
            let offset = wide ? Int(UInt64(bigEndian: bytes, at: base + 8)) : Int(UInt32(bigEndian: bytes, at: base + 8))
            if cpu == 0x0100_000C { return offset }
            if first == nil { first = offset }
        }
        return first
    }

    private static func thinUUID(_ bytes: [UInt8], at start: Int) -> String? {
        guard start + 28 <= bytes.count else { return nil }
        let magic = UInt32(littleEndian: bytes, at: start)
        let header: Int
        switch magic {
        case 0xFEED_FACF: header = 32
        case 0xFEED_FACE: header = 28
        default: return nil
        }
        let commands = Int(UInt32(littleEndian: bytes, at: start + 16))
        var cursor = start + header
        for _ in 0..<commands {
            guard cursor + 8 <= bytes.count else { return nil }
            let command = UInt32(littleEndian: bytes, at: cursor)
            let size = Int(UInt32(littleEndian: bytes, at: cursor + 4))
            if command == 0x1B {
                guard cursor + 24 <= bytes.count else { return nil }
                let raw = Array(bytes[(cursor + 8)..<(cursor + 24)])
                let uuid = UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
                                       raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]))
                return uuid.uuidString
            }
            guard size > 0 else { return nil }
            cursor += size
        }
        return nil
    }
}

private extension UInt32 {
    init(bigEndian bytes: [UInt8], at index: Int) {
        self = bytes[index..<(index + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    init(littleEndian bytes: [UInt8], at index: Int) {
        self = bytes[index..<(index + 4)].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }
}

private extension UInt64 {
    init(bigEndian bytes: [UInt8], at index: Int) {
        self = bytes[index..<(index + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
