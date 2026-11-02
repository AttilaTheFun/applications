import Foundation

/// An XML document as Android compiles it into an APK (AndroidManifest.xml
/// is one): its elements in order, each with its attributes.
struct AndroidBinaryXML: Sendable {
    var elements: [Element]

    struct Element: Sendable {
        var name: String
        var attributes: [Attribute]

        /// The attribute of this name, or of this resource id (an
        /// `android:` attribute's, which a build may keep without its
        /// name).
        func attribute(_ name: String, id: UInt32? = nil) -> Value? {
            attributes.first { attribute in attribute.name == name || (id != nil && attribute.resourceID == id) }?.value
        }
    }

    struct Attribute: Sendable {
        var name: String
        var resourceID: UInt32?
        var value: Value
    }

    /// A value as compiled: a string, a resource it refers to (a string,
    /// a file, which resources.arsc resolves), or a number.
    enum Value: Equatable, Sendable {
        case string(String)
        case reference(UInt32)
        case integer(UInt32)
        case other
    }

    /// The `android:` attributes read from a manifest.
    enum AttributeID {
        static let label: UInt32 = 0x0101_0001
        static let icon: UInt32 = 0x0101_0002
        static let versionCode: UInt32 = 0x0101_021B
        static let versionName: UInt32 = 0x0101_021C
        static let roundIcon: UInt32 = 0x0101_052C
    }

    /// The document in these bytes; nil when they are not one.
    init?(_ data: Data) {
        guard data.uint16(at: 0) == 0x0003, let headerSize = data.uint16(at: 2) else { return nil }
        var pool: AndroidStringPool?
        var resourceIDs: [UInt32] = []
        var elements: [Element] = []
        var offset = Int(headerSize)
        while let type = data.uint16(at: offset), let chunkHeader = data.uint16(at: offset + 2),
              let size = data.uint32(at: offset + 4), size >= 8 {
            switch type {
            case 0x0001:
                pool = AndroidStringPool(data, at: offset)
            case 0x0180:
                resourceIDs = (0..<(Int(size) - Int(chunkHeader)) / 4).compactMap { data.uint32(at: offset + Int(chunkHeader) + $0 * 4) }
            case 0x0102:
                if let pool, let element = Self.element(data, at: offset + Int(chunkHeader), pool: pool, resourceIDs: resourceIDs) {
                    elements.append(element)
                }
            default:
                break
            }
            offset += Int(size)
        }
        self.elements = elements
    }

    /// A start tag's element (ResXMLTree_attrExt): its name, then its
    /// attributes, `attributeSize` bytes each from `attributeStart`.
    private static func element(_ data: Data, at start: Int, pool: AndroidStringPool, resourceIDs: [UInt32]) -> Element? {
        guard let name = data.uint32(at: start + 4), let attributeStart = data.uint16(at: start + 8),
              let attributeSize = data.uint16(at: start + 10), let count = data.uint16(at: start + 12) else { return nil }
        let attributes = (0..<Int(count)).compactMap { index -> Attribute? in
            let at = start + Int(attributeStart) + index * Int(attributeSize)
            guard let name = data.uint32(at: at + 4), let raw = data.uint32(at: at + 8),
                  let type = data.uint8(at: at + 15), let value = data.uint32(at: at + 16) else { return nil }
            return Attribute(name: pool[name] ?? "", resourceID: Int(name) < resourceIDs.count ? resourceIDs[Int(name)] : nil,
                             value: Self.value(type: type, data: value, raw: raw, pool: pool))
        }
        return Element(name: pool[name] ?? "", attributes: attributes)
    }

    /// A typed value (Res_value) as read: its type, and its data.
    static func value(type: UInt8, data: UInt32, raw: UInt32 = 0xFFFF_FFFF, pool: AndroidStringPool?) -> Value {
        switch type {
        case 0x03: return pool?[data].map(Value.string) ?? .other
        case 0x01: return .reference(data)
        case 0x10...0x1F: return .integer(data)
        default: return raw != 0xFFFF_FFFF ? pool?[raw].map(Value.string) ?? .other : .other
        }
    }
}
