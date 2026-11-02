import Foundation

extension Data {
    /// The little-endian number of this width at `offset` (from the
    /// data's start), or nil past the end: how Android's compiled files
    /// and zip archives store theirs.
    func uint8(at offset: Int) -> UInt8? { littleEndian(at: offset, width: 1).map(UInt8.init) }
    func uint16(at offset: Int) -> UInt16? { littleEndian(at: offset, width: 2).map(UInt16.init) }
    func uint32(at offset: Int) -> UInt32? { littleEndian(at: offset, width: 4).map(UInt32.init) }
    func uint64(at offset: Int) -> UInt64? { littleEndian(at: offset, width: 8) }

    /// The `length` bytes at `offset`, starting at 0; nil past the end.
    func bytes(at offset: Int, length: Int) -> Data? {
        guard offset >= 0, length >= 0, length <= count - offset else { return nil }
        return subdata(in: startIndex + offset ..< startIndex + offset + length)
    }

    private func littleEndian(at offset: Int, width: Int) -> UInt64? {
        guard offset >= 0, width <= count - offset else { return nil }
        return (0..<width).reversed().reduce(0) { $0 << 8 | UInt64(self[startIndex + offset + $1]) }
    }
}
