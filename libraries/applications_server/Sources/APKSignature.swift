import CryptoKit
import Foundation

/// An APK's signing block (APK Signature Scheme v2, v3, v3.1), which
/// Android requires of an app it installs: it sits between the archive's
/// files and its central directory, and names the certificate the app is
/// signed with, which every update of the app must share.
enum APKSignature {
    /// The schemes' ids in the block, the latest first: v3.1, v3, v2.
    static let schemes: [UInt32] = [0x1B93_AD61, 0xF053_68C0, 0x7109_871A]
    static let magic = Data("APK Sig Block 42".utf8)

    /// The SHA-256 of the certificate the APK is signed with, in lowercase
    /// hex (as `apksigner verify --print-certs` gives it); a refusal when it
    /// has no signing block of v2 or later, which Android would not install.
    static func signer(of apk: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: apk)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        guard let directory = try centralDirectory(handle, length: length), directory >= 24 else {
            throw PackageCheck.Refusal("It is not a zip archive an APK would be")
        }
        try handle.seek(toOffset: directory - 24)
        guard let footer = try handle.read(upToCount: 24), footer.bytes(at: 8, length: 16) == magic,
              let size = footer.uint64(at: 0), size >= 32, size <= 64 << 20, size + 8 <= directory else {
            throw PackageCheck.Refusal("It is not signed with APK Signature Scheme v2 or later, so Android would not install it")
        }
        try handle.seek(toOffset: directory - size - 8)
        guard let block = try handle.read(upToCount: Int(size) + 8), block.uint64(at: 0) == size else {
            throw PackageCheck.Refusal("Its APK signing block is damaged")
        }
        let pairs = Self.pairs(block.bytes(at: 8, length: Int(size) - 24) ?? Data())
        guard let certificate = schemes.lazy.compactMap({ pairs[$0].flatMap(firstCertificate) }).first else {
            throw PackageCheck.Refusal("It is not signed with APK Signature Scheme v2 or later, so Android would not install it")
        }
        return SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
    }

    /// Where the central directory starts, from the end of central
    /// directory record (in the archive's last 64 KB, behind its comment).
    static func centralDirectory(_ handle: FileHandle, length: UInt64) throws -> UInt64? {
        let tail = min(length, 22 + 0xFFFF)
        try handle.seek(toOffset: length - tail)
        guard let data = try handle.read(upToCount: Int(tail)), data.count >= 22 else { return nil }
        for start in stride(from: data.count - 22, through: 0, by: -1) where data.uint32(at: start) == 0x0605_4B50 {
            guard let offset = data.uint32(at: start + 16), offset != 0xFFFF_FFFF else { return nil }
            return UInt64(offset)
        }
        return nil
    }

    /// The block's pairs: an eight-byte length, a four-byte id, the value.
    static func pairs(_ data: Data) -> [UInt32: Data] {
        var pairs: [UInt32: Data] = [:]
        var offset = 0
        while let length = data.uint64(at: offset), length >= 4, length <= UInt64(data.count - offset - 8),
              let id = data.uint32(at: offset + 8) {
            pairs[id] = data.bytes(at: offset + 12, length: Int(length) - 4)
            offset += 8 + Int(length)
        }
        return pairs
    }

    /// A scheme's first signer's first certificate (DER): its signers,
    /// the first one's signed data, then past its digests to its
    /// certificates — each a sequence with a four-byte length before it.
    static func firstCertificate(_ scheme: Data) -> Data? {
        guard let signers = lengthPrefixed(scheme, at: 0), let signer = lengthPrefixed(signers, at: 0),
              let signed = lengthPrefixed(signer, at: 0), let digests = lengthPrefixed(signed, at: 0),
              let certificates = lengthPrefixed(signed, at: 4 + digests.count),
              let certificate = lengthPrefixed(certificates, at: 0), !certificate.isEmpty else { return nil }
        return certificate
    }

    private static func lengthPrefixed(_ data: Data, at offset: Int) -> Data? {
        data.uint32(at: offset).flatMap { data.bytes(at: offset + 4, length: Int($0)) }
    }
}
