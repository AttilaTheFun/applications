import Foundation

/// An APK's compiled resources (resources.arsc): each resource id's
/// values, one for each configuration it has (a language, a screen
/// density…).
struct AndroidResources: Sendable {
    private var values: [UInt32: [Entry]] = [:]

    /// One configuration's value.
    struct Entry: Sendable {
        /// Two letters, or empty for the default language.
        var language: String
        /// Dots per inch (160 is mdpi, 640 xxxhdpi); 0 is the default,
        /// 0xFFFE any (a vector or an adaptive icon), 0xFFFF none.
        var density: UInt16
        var value: AndroidBinaryXML.Value
    }

    /// The resources in these bytes; nil when they are not resources.
    init?(_ data: Data) {
        guard data.uint16(at: 0) == 0x0002, let headerSize = data.uint16(at: 2) else { return nil }
        var pool: AndroidStringPool?
        var offset = Int(headerSize)
        while let type = data.uint16(at: offset), let size = data.uint32(at: offset + 4), size >= 8 {
            switch type {
            case 0x0001: pool = AndroidStringPool(data, at: offset)
            case 0x0200: readPackage(data, at: offset, size: Int(size), pool: pool)
            default: break
            }
            offset += Int(size)
        }
    }

    /// A string resource, in the default language when it has one, the
    /// references it makes followed.
    func string(_ id: UInt32, depth: Int = 0) -> String? {
        let entries = values[id] ?? []
        switch (entries.first { $0.language.isEmpty } ?? entries.first)?.value {
        case .string(let text): return text
        case .reference(let other) where depth < 8: return string(other, depth: depth + 1)
        default: return nil
        }
    }

    /// A file resource's files (paths in the APK), with the density each
    /// is for, the references it makes followed.
    func files(_ id: UInt32, depth: Int = 0) -> [(path: String, density: UInt16)] {
        (values[id] ?? []).flatMap { entry -> [(path: String, density: UInt16)] in
            switch entry.value {
            case .string(let path): return [(path, entry.density)]
            case .reference(let other) where depth < 8: return files(other, depth: depth + 1)
            default: return []
            }
        }
    }

    /// A package (ResTable_package): its types' values. Its names for
    /// types and keys are not needed.
    private mutating func readPackage(_ data: Data, at start: Int, size: Int, pool: AndroidStringPool?) {
        guard let packageID = data.uint32(at: start + 8), let headerSize = data.uint16(at: start + 2) else { return }
        var offset = start + Int(headerSize)
        while offset < start + size, let type = data.uint16(at: offset), let chunkSize = data.uint32(at: offset + 4), chunkSize >= 8 {
            if type == 0x0201 { readType(data, at: offset, packageID: packageID, pool: pool) }
            offset += Int(chunkSize)
        }
    }

    /// One type's values in one configuration (ResTable_type): the
    /// configuration, then where each entry is — four bytes each, two
    /// (FLAG_OFFSET16), or an index and an offset (FLAG_SPARSE).
    private mutating func readType(_ data: Data, at start: Int, packageID: UInt32, pool: AndroidStringPool?) {
        guard let headerSize = data.uint16(at: start + 2), let typeID = data.uint8(at: start + 8), let flags = data.uint8(at: start + 9),
              let count = data.uint32(at: start + 12), let entriesStart = data.uint32(at: start + 16),
              let language = data.bytes(at: start + 28, length: 2), let density = data.uint16(at: start + 34) else { return }
        let languageText = language.allSatisfy { $0 == 0 } ? "" : String(decoding: language, as: UTF8.self)
        let sparse = flags & 0x01 != 0, offset16 = flags & 0x02 != 0
        for index in 0..<Int(count) {
            let at = start + Int(headerSize)
            let place: (entry: Int, offset: Int)?
            if sparse {
                place = data.uint16(at: at + index * 4).flatMap { entry in data.uint16(at: at + index * 4 + 2).map { (Int(entry), Int($0) * 4) } }
            } else if offset16 {
                place = data.uint16(at: at + index * 2).flatMap { $0 == 0xFFFF ? nil : (index, Int($0) * 4) }
            } else {
                place = data.uint32(at: at + index * 4).flatMap { $0 == 0xFFFF_FFFF ? nil : (index, Int($0)) }
            }
            guard let place, let value = Self.value(data, at: start + Int(entriesStart) + place.offset, pool: pool) else { continue }
            let id = packageID << 24 | UInt32(typeID) << 16 | UInt32(place.entry)
            values[id, default: []].append(Entry(language: languageText, density: density, value: value))
        }
    }

    /// An entry's value (ResTable_entry): compact (FLAG_COMPACT: the type
    /// in its flags, the data after them), a map (FLAG_COMPLEX: a style
    /// or the like, not read), or a value after the entry's header.
    private static func value(_ data: Data, at start: Int, pool: AndroidStringPool?) -> AndroidBinaryXML.Value? {
        guard let size = data.uint16(at: start), let flags = data.uint16(at: start + 2) else { return nil }
        if flags & 0x0008 != 0 {
            return data.uint32(at: start + 4).map { AndroidBinaryXML.value(type: UInt8(flags >> 8), data: $0, pool: pool) }
        }
        guard flags & 0x0001 == 0, let type = data.uint8(at: start + Int(size) + 3),
              let value = data.uint32(at: start + Int(size) + 4) else { return nil }
        return AndroidBinaryXML.value(type: type, data: value, pool: pool)
    }
}
