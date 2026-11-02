import CryptoKit
import Foundation
import Security

/// A server's own certificate authority, and the HTTPS certificate it
/// issues for every address the server is reached at: a LAN or tailnet IP
/// has no public certificate, so the apps pin this authority (its
/// fingerprint is in the connection code), and a phone that installs over
/// the air trusts it once (its profile, from the server's plain HTTP port).
/// Made with the system's openssl; kept in tls/. Where a client checks the
/// certificate's revocation (Windows' Schannel, which curl and URLSession
/// use there, fails one that names no list), the certificate names the
/// authority's revocation list, served on the plain port: empty, as nothing
/// is revoked.
public struct CertificateAuthority: Sendable {
    let folder: URL
    /// What the authority is named for ("Applications": "Applications CA (…)").
    let name: String
    static let openssl = "/usr/bin/openssl"

    public init(folder: URL, name: String) {
        self.folder = folder
        self.name = name
    }

    /// The identity file's password: it never leaves tls/, which is this
    /// user's alone, but the system's importer wants one.
    var identityPassword: String { name.lowercased() }

    var caKey: URL { folder.appendingPathComponent("ca.key") }
    var caCertificate: URL { folder.appendingPathComponent("ca.pem") }
    var serverKey: URL { folder.appendingPathComponent("server.key") }
    var serverCertificate: URL { folder.appendingPathComponent("server.pem") }
    var identityFile: URL { folder.appendingPathComponent("server.p12") }
    var namesFile: URL { folder.appendingPathComponent("server.names") }
    var revocationListFile: URL { folder.appendingPathComponent("ca.crl") }

    /// The authority made, if it is not yet, and a server certificate for
    /// exactly `names` (IP addresses and host names), naming the revocation
    /// list at `revocationURLs` (none: no list named), issued again when
    /// either changes. Whether it issued one.
    @discardableResult
    public func ensure(names: [String], title: String, revocationURLs: [String] = []) throws -> Bool {
        if !FileManager.default.fileExists(atPath: caCertificate.path) { try makeAuthority(title: title) }
        let wanted = (names + revocationURLs.map { Self.revocationLine + $0 }).joined(separator: "\n")
        let issued = (try? String(contentsOf: namesFile, encoding: .utf8)) ?? ""
        guard issued != wanted || !FileManager.default.fileExists(atPath: identityFile.path) else { return false }
        try issue(names: names, title: title, revocationURLs: revocationURLs)
        try wanted.write(to: namesFile, atomically: true, encoding: .utf8)
        return true
    }

    /// How a revocation list's address is written down beside the names.
    static let revocationLine = "crl "

    /// The names the current certificate was issued for.
    public var issuedNames: [String] {
        ((try? String(contentsOf: namesFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix(Self.revocationLine) }
    }

    /// The authority's revocation list, DER: empty (nothing is revoked),
    /// good for 30 days, and signed again once it is a week old, so a client
    /// that keeps it until it runs out never holds a stale one.
    public func revocationList(now: Date = Date()) throws -> Data {
        let age = (try? FileManager.default.attributesOfItem(atPath: revocationListFile.path)[.modificationDate] as? Date).map { now.timeIntervalSince($0) }
        if let age, age < 7 * 24 * 3600, let data = try? Data(contentsOf: revocationListFile) { return data }
        let database = folder.appendingPathComponent("ca.index")
        let number = folder.appendingPathComponent("ca.crlnumber")
        if !FileManager.default.fileExists(atPath: database.path) { try Data().write(to: database) }
        if !FileManager.default.fileExists(atPath: number.path) { try "01\n".write(to: number, atomically: true, encoding: .utf8) }
        let config = folder.appendingPathComponent("ca-crl.cnf")
        try """
        [ca]
        default_ca = authority
        [authority]
        database = \(database.path)
        crlnumber = \(number.path)
        private_key = \(caKey.path)
        certificate = \(caCertificate.path)
        default_md = sha256
        default_crl_days = 30
        crl_extensions = crl_ext
        [crl_ext]
        authorityKeyIdentifier = keyid:always
        """.write(to: config, atomically: true, encoding: .utf8)
        let pem = folder.appendingPathComponent("ca.crl.pem")
        try ProcessRunner.run(Self.openssl, ["ca", "-gencrl", "-config", config.path, "-out", pem.path])
        try ProcessRunner.run(Self.openssl, ["crl", "-in", pem.path, "-outform", "DER", "-out", revocationListFile.path])
        return try Data(contentsOf: revocationListFile)
    }

    /// The authority's certificate, PEM: what a Linux or Windows computer
    /// installs among its trusted roots.
    public func authorityPEM() throws -> Data { try Data(contentsOf: caCertificate) }

    private func makeAuthority(title: String) throws {
        let config = folder.appendingPathComponent("ca.cnf")
        try """
        [req]
        distinguished_name = dn
        x509_extensions = ext
        prompt = no
        [dn]
        CN = \(name) CA (\(ascii(title)))
        O = \(name)
        [ext]
        basicConstraints = critical,CA:TRUE
        keyUsage = critical,keyCertSign,cRLSign
        subjectKeyIdentifier = hash
        """.write(to: config, atomically: true, encoding: .utf8)
        try ProcessRunner.run(Self.openssl, ["req", "-x509", "-new", "-nodes", "-newkey", "rsa:2048", "-sha256", "-days", "3650",
                                             "-keyout", caKey.path, "-out", caCertificate.path, "-config", config.path])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: caKey.path)
    }

    private func issue(names: [String], title: String, revocationURLs: [String]) throws {
        let request = folder.appendingPathComponent("server.csr")
        let extensions = folder.appendingPathComponent("server.ext")
        let alternatives = names.map { Self.isIP($0) ? "IP:\($0)" : "DNS:\($0)" }.joined(separator: ",")
        let revocation = revocationURLs.isEmpty ? "" : "\ncrlDistributionPoints = " + revocationURLs.map { "URI:" + $0 }.joined(separator: ",")
        try """
        basicConstraints = CA:FALSE
        keyUsage = critical,digitalSignature,keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = \(alternatives)
        subjectKeyIdentifier = hash
        authorityKeyIdentifier = keyid,issuer\(revocation)
        """.write(to: extensions, atomically: true, encoding: .utf8)
        try ProcessRunner.run(Self.openssl, ["req", "-new", "-nodes", "-newkey", "rsa:2048", "-sha256", "-keyout", serverKey.path,
                                             "-out", request.path, "-subj", "/CN=\(ascii(title))/O=\(name)"])
        // Within the 825 days iOS accepts for a server certificate.
        try ProcessRunner.run(Self.openssl, ["x509", "-req", "-in", request.path, "-CA", caCertificate.path, "-CAkey", caKey.path,
                                             "-CAcreateserial", "-out", serverCertificate.path, "-days", "800", "-sha256",
                                             "-extfile", extensions.path])
        try ProcessRunner.run(Self.openssl, ["pkcs12", "-export", "-inkey", serverKey.path, "-in", serverCertificate.path,
                                             "-certfile", caCertificate.path, "-out", identityFile.path,
                                             "-passout", "pass:\(identityPassword)",
                                             "-certpbe", "PBE-SHA1-3DES", "-keypbe", "PBE-SHA1-3DES"])
        for file in [serverKey, identityFile] {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    /// The authority's certificate, DER.
    public func authorityDER() throws -> Data {
        let pem = try String(contentsOf: caCertificate, encoding: .utf8)
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body) else { throw CocoaError(.fileReadCorruptFile) }
        return der
    }

    /// SHA-256 of the authority's certificate, lowercase hex: what the
    /// connection code carries for the app to pin.
    public func fingerprint() throws -> String {
        SHA256.hash(data: try authorityDER()).map { String(format: "%02x", $0) }.joined()
    }

    /// The server's identity (its key and certificate) and the authority's
    /// certificate, for the TLS listener to present as a chain.
    public func identity() throws -> (SecIdentity, SecCertificate) {
        let data = try Data(contentsOf: identityFile)
        var items: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: identityPassword,
                                      kSecImportToMemoryOnly as String: true]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let found = first[kSecImportItemIdentity as String] else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        // A CFTypeRef that is a SecIdentity: checked by its type id.
        guard CFGetTypeID(found as CFTypeRef) == SecIdentityGetTypeID() else { throw CocoaError(.fileReadCorruptFile) }
        let identity = found as! SecIdentity
        guard let authority = SecCertificateCreateWithData(nil, try authorityDER() as CFData) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (identity, authority)
    }

    /// A configuration profile that installs the authority as a root: what
    /// the phone opens in Safari, once. Named for the server's app; its
    /// identifiers are the server's id, so a device that installs it again
    /// replaces the one it has.
    public func profile(serverID: String, title: String, purpose: String) throws -> Data {
        let der = try authorityDER()
        let payload: [String: Any] = [
            "PayloadType": "com.apple.security.root",
            "PayloadVersion": 1,
            "PayloadIdentifier": "\(name.lowercased()).\(serverID).ca",
            "PayloadUUID": Self.uuid(serverID + ".ca"),
            "PayloadDisplayName": "\(name) CA",
            "PayloadContent": der,
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": "\(name.lowercased()).\(serverID)",
            "PayloadUUID": Self.uuid(serverID),
            "PayloadDisplayName": "\(name) (\(title))",
            "PayloadDescription": purpose,
            "PayloadContent": [payload],
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    /// A UUID made from a string, the same each time.
    static func uuid(_ seed: String) -> String {
        let bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.map(String.init).joined(separator: "-")
    }

    static func isIP(_ name: String) -> Bool {
        let parts = name.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// A name openssl takes in a subject: plain letters, digits, spaces.
    func ascii(_ text: String) -> String {
        let kept = text.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-") }
        let plain = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
        return plain.isEmpty ? name : plain
    }
}
