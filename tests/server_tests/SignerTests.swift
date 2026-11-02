import Foundation
import PipelineServer
import XCTest
@testable import ApplicationsServer

/// Signing on the server (Signer), with a fake codesign and notary: an
/// iPhone app's bundles signed inside out, each app and extension with the
/// profile for its own bundle id, all of one kind; a bundle with no profile
/// refusing the build untouched; a Mac app with Developer ID, every Mach-O
/// in it first, the deepest first, each with its own entitlements and
/// identifier, notarized and stapled unless the notary says it notarized
/// nothing.
final class SignerTests: XCTestCase {
    /// An iPhone app as CI sends it: an extension with a framework of its
    /// own, a framework, a library and a resource bundle (no code) in it.
    private func nestedIPA(in folder: URL) throws -> URL {
        let work = folder.appendingPathComponent(UUID().uuidString)
        let app = work.appendingPathComponent("Payload/Visor.app")
        try bundle(app, id: "com.example.Visor", executable: "Visor")
        try bundle(app.appendingPathComponent("Frameworks/Kit.framework"), id: "com.example.Kit", executable: "Kit")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Frameworks/libswiftKit.dylib"))
        let widgets = app.appendingPathComponent("PlugIns/Widgets.appex")
        try bundle(widgets, id: "com.example.Visor.Widgets", executable: "Widgets")
        try bundle(widgets.appendingPathComponent("Frameworks/Inner.framework"), id: "com.example.Inner", executable: "Inner")
        try bundle(app.appendingPathComponent("Assets.bundle"), id: "com.example.Assets", executable: nil)
        let ipa = folder.appendingPathComponent(UUID().uuidString + ".ipa")
        try ProcessRunner.run("/usr/bin/zip", ["-q", "-r", "-y", ipa.path, "Payload"], in: work)
        return ipa
    }

    /// A shallow bundle (an iPhone one's layout): its Info.plist and its
    /// executable, a copy of /usr/bin/true, at its top.
    private func bundle(_ folder: URL, id: String, executable: String?) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": id]
        if let executable {
            info["CFBundleExecutable"] = executable
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: folder.appendingPathComponent(executable))
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: folder.appendingPathComponent("Info.plist"))
    }

    private func signer(_ signing: FakeCodeSigning, profiles: URL, notary: (any Notarizing)? = nil) -> Signer {
        Signer(tools: signing, notary: notary ?? FakeNotary(accepts: true, events: signing.events), profiles: profiles, team: TestProfile.team)
    }

    func testEveryBundleIsSignedInsideOutWithItsOwnProfile() throws {
        let folder = TestIPA.folder()
        let profiles = folder.appendingPathComponent("profiles")
        try TestProfile.write(in: profiles, bundleID: "com.example.Visor")
        try TestProfile.write(in: profiles, bundleID: "com.example.Visor.Widgets")
        let signing = FakeCodeSigning()
        let ipa = try nestedIPA(in: folder)
        try signer(signing, profiles: profiles).sign(ipa: ipa, .development)
        let development = TestProfile.sha1(.development)
        XCTAssertEqual(signing.signed, [
            FakeCodeSigning.Signed(path: "Visor.app/PlugIns/Widgets.appex/Frameworks/Inner.framework", identity: development,
                                   hardenedRuntime: false, timestamp: false),
            FakeCodeSigning.Signed(path: "Visor.app/Frameworks/Kit.framework", identity: development, hardenedRuntime: false, timestamp: false),
            FakeCodeSigning.Signed(path: "Visor.app/Frameworks/libswiftKit.dylib", identity: development, hardenedRuntime: false, timestamp: false),
            FakeCodeSigning.Signed(path: "Visor.app/PlugIns/Widgets.appex", identity: development, hardenedRuntime: false, timestamp: false,
                                   applicationIdentifier: "\(TestProfile.team).com.example.Visor.Widgets", debuggable: true,
                                   profile: TestProfile.name("development", "com.example.Visor.Widgets")),
            FakeCodeSigning.Signed(path: "Visor.app", identity: development, hardenedRuntime: false, timestamp: false,
                                   applicationIdentifier: "\(TestProfile.team).com.example.Visor", debuggable: true,
                                   profile: TestProfile.name("development", "com.example.Visor")),
        ], "inside out; the resource bundle, which has no code, is the app's to seal")
        let entries = String(decoding: try ProcessRunner.run("/usr/bin/unzip", ["-Z1", ipa.path]), as: UTF8.self)
        XCTAssertTrue(entries.contains("Payload/Visor.app/PlugIns/Widgets.appex/embedded.mobileprovision"))
        XCTAssertTrue(entries.contains("Payload/Visor.app/embedded.mobileprovision"))
        XCTAssertTrue(entries.contains("Payload/Visor.app/Assets.bundle/Info.plist"))
    }

    /// Production takes ad hoc profiles when every bundle has one (one
    /// certificate throughout), else development ones, as a beta's.
    func testProductionIsAdHocOnlyWhenEveryBundleHasAnAdHocProfile() throws {
        let folder = TestIPA.folder()
        let profiles = folder.appendingPathComponent("profiles")
        for id in ["com.example.Visor", "com.example.Visor.Widgets"] { try TestProfile.write(in: profiles, bundleID: id) }
        try TestProfile.write(in: profiles, bundleID: "com.example.Visor", kind: "ad hoc")
        let partly = FakeCodeSigning()
        try signer(partly, profiles: profiles).sign(ipa: try nestedIPA(in: folder), .production)
        XCTAssertEqual(Set(partly.signed.map(\.identity)), [TestProfile.sha1(.development)])
        try TestProfile.write(in: profiles, bundleID: "com.example.Visor.Widgets", kind: "ad hoc")
        // An App Store profile installs nothing over the air: passed over.
        try TestProfile.write(in: profiles, bundleID: "com.example.Visor.Widgets", kind: "App Store")
        let wholly = FakeCodeSigning()
        try signer(wholly, profiles: profiles).sign(ipa: try nestedIPA(in: folder), .production)
        XCTAssertEqual(Set(wholly.signed.map(\.identity)), [TestProfile.sha1(.distribution)])
        XCTAssertEqual(wholly.signed.compactMap(\.profile), [TestProfile.name("ad hoc", "com.example.Visor.Widgets"),
                                                             TestProfile.name("ad hoc", "com.example.Visor")])
        XCTAssertEqual(Set(wholly.signed.compactMap(\.debuggable)), [false])
    }

    /// A bundle without a profile here refuses the whole build, naming its
    /// bundle id, before anything in it is signed; so does an expired
    /// profile, saying so.
    func testAMissingProfileRefusesTheBuildUntouched() throws {
        let folder = TestIPA.folder()
        let profiles = folder.appendingPathComponent("profiles")
        try TestProfile.write(in: profiles, bundleID: "com.example.Visor")
        try TestProfile.write(in: profiles, bundleID: "com.example.Visor.Widgets", expires: Date().addingTimeInterval(-86_400))
        let signing = FakeCodeSigning()
        let ipa = try nestedIPA(in: folder)
        let uploaded = try Data(contentsOf: ipa)
        XCTAssertThrowsError(try signer(signing, profiles: profiles).sign(ipa: ipa, .development)) { error in
            XCTAssertTrue("\(error)".hasPrefix("No development profile for com.example.Visor.Widgets in \(profiles.path)"), "\(error)")
            XCTAssertTrue("\(error)".contains("expired on"), "\(error)")
        }
        XCTAssertEqual(signing.signed, [])
        XCTAssertEqual(try Data(contentsOf: ipa), uploaded)
        // Nor without an identity for the profile's certificate.
        try TestProfile.write(in: profiles, bundleID: "com.example.Visor.Widgets")
        let without = FakeCodeSigning(identities: TestProfile.identities.filter { $0.kind != .development })
        XCTAssertThrowsError(try signer(without, profiles: profiles).sign(ipa: ipa, .development)) { error in
            XCTAssertTrue("\(error)".contains("No identity in this Mac's keychain"), "\(error)")
            XCTAssertFalse("\(error)".contains(TestProfile.team), "the team stays out of it")
        }
        XCTAssertEqual(without.signed, [])
    }

    /// A bundle's own entitlements, made its profile's: the profile's
    /// application identifier, team and keychain groups, push environment
    /// and debugging; one the profile does not allow refuses it.
    func testABundlesEntitlementsAreMadeItsProfiles() throws {
        let folder = TestIPA.folder()
        let file = try TestProfile.write(in: folder, bundleID: "com.example.Visor", kind: "ad hoc")
        let profile = try XCTUnwrap(ProvisioningProfile(file: file, plist: try Data(contentsOf: file)))
        XCTAssertEqual(profile.kind, .adHoc)
        XCTAssertEqual(profile.bundleID, "com.example.Visor")
        let own: [String: Any] = ["application-identifier": "OLDTEAM123.com.example.Visor", "aps-environment": "development",
                                  "get-task-allow": true,
                                  "keychain-access-groups": ["$(AppIdentifierPrefix)com.example.Visor", "OLDTEAM123.com.example.Shared"]]
        let made = try Signer.entitlements(own, bundleID: "com.example.Visor", profile: profile)
        XCTAssertEqual(made["application-identifier"] as? String, "\(TestProfile.team).com.example.Visor")
        XCTAssertEqual(made["com.apple.developer.team-identifier"] as? String, TestProfile.team)
        XCTAssertEqual(made["aps-environment"] as? String, "production")
        XCTAssertEqual(made["get-task-allow"] as? Bool, false)
        XCTAssertEqual(made["keychain-access-groups"] as? [String],
                       ["\(TestProfile.team).com.example.Visor", "\(TestProfile.team).com.example.Shared"])
        // A bundle that came with none takes the profile's, its wildcards
        // made its own or left out.
        let given = try Signer.entitlements([:], bundleID: "com.example.Visor", profile: profile)
        XCTAssertEqual(given["keychain-access-groups"] as? [String], ["\(TestProfile.team).com.example.Visor", "com.apple.token"])
        XCTAssertEqual(given["com.apple.developer.team-identifier"] as? String, TestProfile.team)
        XCTAssertThrowsError(try Signer.entitlements(own.merging(["com.apple.developer.icloud-services": ["CloudKit"]]) { $1 },
                                                     bundleID: "com.example.Visor", profile: profile)) { error in
            XCTAssertTrue("\(error)".contains("does not allow com.apple.developer.icloud-services"), "\(error)")
        }
        let noPushFile = try TestProfile.write(in: folder.appendingPathComponent("other"), bundleID: "com.example.Visor", push: false)
        let noPush = try XCTUnwrap(ProvisioningProfile(file: noPushFile, plist: try Data(contentsOf: noPushFile)))
        XCTAssertThrowsError(try Signer.entitlements(own, bundleID: "com.example.Visor", profile: noPush)) { error in
            XCTAssertTrue("\(error)".contains("does not allow aps-environment"), "\(error)")
        }
    }

    /// A Mac app as CI sends it: a versioned framework (its links not
    /// followed) and a helper beside its executable.
    private func macZip(in folder: URL) throws -> URL {
        let work = folder.appendingPathComponent(UUID().uuidString)
        let contents = work.appendingPathComponent("Visor.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.VisorMac", "CFBundleExecutable": "Visor"],
                                           format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        for name in ["Visor", "visor-helper"] {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: contents.appendingPathComponent("MacOS/" + name))
        }
        let framework = contents.appendingPathComponent("Frameworks/Kit.framework")
        let version = framework.appendingPathComponent("Versions/A")
        try FileManager.default.createDirectory(at: version.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: version.appendingPathComponent("Kit"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.Kit", "CFBundleExecutable": "Kit"],
                                           format: .xml, options: 0).write(to: version.appendingPathComponent("Resources/Info.plist"))
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Kit").path, withDestinationPath: "Versions/Current/Kit")
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Resources").path,
                                                   withDestinationPath: "Versions/Current/Resources")
        let zip = folder.appendingPathComponent(UUID().uuidString + ".zip")
        try ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", work.appendingPathComponent("Visor.app").path, zip.path])
        return zip
    }

    func testAMacAppIsSignedWithDeveloperIDNestedCodeFirstThenNotarizedAndStapled() throws {
        let folder = TestIPA.folder()
        let signing = FakeCodeSigning(ownEntitlements: ["Visor.app": ["com.apple.security.app-sandbox": true,
                                                                      "com.apple.security.get-task-allow": true]])
        let zip = try macZip(in: folder)
        let result = try signer(signing, profiles: folder.appendingPathComponent("profiles")).sign(macZip: zip)
        XCTAssertEqual(result, .accepted(submission: "test-submission"))
        XCTAssertEqual(signing.events.all, ["sign Visor.app/Contents/Frameworks/Kit.framework", "sign Visor.app/Contents/MacOS/visor-helper",
                                            "sign Visor.app", "notarize", "staple Visor.app"])
        let developerID = TestProfile.sha1(.developerID)
        XCTAssertEqual(Set(signing.signed.map(\.identity)), [developerID])
        XCTAssertEqual(Set(signing.signed.map(\.hardenedRuntime)), [true])
        XCTAssertEqual(Set(signing.signed.map(\.timestamp)), [true])
        XCTAssertNil(signing.signed.last?.debuggable, "debugging is no notarized app's")
        let entries = String(decoding: try ProcessRunner.run("/usr/bin/unzip", ["-Z1", zip.path]), as: UTF8.self)
        XCTAssertTrue(entries.contains("Visor.app/Contents/MacOS/visor-helper"), "zipped again")
    }

    /// A Mac app that bundles a tool, as OS Server bundles QEMU: the tool's
    /// executable deep in Contents/Helpers and a library beside it, a
    /// framework with a helper of its own, and the tool's firmware and a
    /// script (no code, however executable) in Resources.
    private func toolZip(in folder: URL) throws -> URL {
        let work = folder.appendingPathComponent(UUID().uuidString)
        let contents = work.appendingPathComponent("Tool.app/Contents")
        let framework = contents.appendingPathComponent("Frameworks/Kit.framework")
        // A copy of /usr/bin/true (a real Mach-O), or an Info.plist, with the
        // folders it is in.
        func machO(_ file: URL) throws {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: file)
        }
        func info(_ info: [String: Any], at file: URL) throws {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: file)
        }
        try info(["CFBundleIdentifier": "com.example.Tool", "CFBundleExecutable": "Tool"], at: contents.appendingPathComponent("Info.plist"))
        try machO(contents.appendingPathComponent("MacOS/Tool"))
        try machO(contents.appendingPathComponent("Helpers/tool/bin/a"))
        try machO(contents.appendingPathComponent("Helpers/lib/x.dylib"))
        try machO(framework.appendingPathComponent("Versions/A/Kit"))
        try machO(framework.appendingPathComponent("Versions/A/Helpers/kit-tool"))
        try info(["CFBundleIdentifier": "com.example.Kit", "CFBundleExecutable": "Kit"],
                 at: framework.appendingPathComponent("Versions/A/Resources/Info.plist"))
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Kit").path, withDestinationPath: "Versions/Current/Kit")
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Resources").path,
                                                   withDestinationPath: "Versions/Current/Resources")
        let resources = contents.appendingPathComponent("Resources/tool")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("firmware".utf8).write(to: resources.appendingPathComponent("firmware.fd"))
        try Data("#!/bin/sh\nexec \"$(dirname \"$0\")/../../Helpers/tool/bin/a\"\n".utf8).write(to: resources.appendingPathComponent("start"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resources.appendingPathComponent("start").path)
        let zip = folder.appendingPathComponent(UUID().uuidString + ".zip")
        try ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", work.appendingPathComponent("Tool.app").path, zip.path])
        return zip
    }

    /// Every Mach-O file in a Mac app is signed, wherever it is, the
    /// deepest first and each bundle after what is in it, each with its own
    /// entitlements and identifier; a bundle's own executable is signed
    /// with its bundle, and what is not code is left to the app's seal.
    func testEveryMachOInAMacAppIsSignedDeepestFirstWithItsOwnEntitlementsAndIdentifier() throws {
        let folder = TestIPA.folder()
        let signing = FakeCodeSigning(
            ownEntitlements: ["Tool.app": ["com.apple.security.virtualization": true],
                              "a": ["com.apple.security.hypervisor": true, "com.apple.security.get-task-allow": true],
                              "kit-tool": ["com.apple.security.cs.allow-jit": true]],
            ownIdentifiers: ["Tool.app": "com.example.Tool", "a": "org.example.a", "x.dylib": "libx", "Kit.framework": "com.example.Kit",
                             "kit-tool": "com.example.Kit.tool"])
        let zip = try toolZip(in: folder)
        let result = try signer(signing, profiles: folder.appendingPathComponent("profiles")).sign(macZip: zip)
        XCTAssertEqual(result, .accepted(submission: "test-submission"))
        XCTAssertEqual(signing.events.all, ["sign Tool.app/Contents/Frameworks/Kit.framework/Versions/A/Helpers/kit-tool",
                                            "sign Tool.app/Contents/Helpers/tool/bin/a",
                                            "sign Tool.app/Contents/Helpers/lib/x.dylib",
                                            "sign Tool.app/Contents/Frameworks/Kit.framework",
                                            "sign Tool.app", "notarize", "staple Tool.app"],
                       "deepest first; the app's and the framework's own executables with their bundles; the links, the firmware and "
                       + "the script not at all")
        XCTAssertEqual(signing.signed.map(\.identifier), ["com.example.Kit.tool", "org.example.a", "libx", "com.example.Kit", nil],
                       "each its own; the app's is its bundle id, codesign's own")
        XCTAssertEqual(Set(signing.signed.map(\.identity)), [TestProfile.sha1(.developerID)])
        XCTAssertEqual(Set(signing.signed.map(\.hardenedRuntime)), [true])
        XCTAssertEqual(Set(signing.signed.map(\.timestamp)), [true])
        XCTAssertEqual(signing.entitlementsGiven("Tool.app/Contents/Helpers/tool/bin/a"),
                       ["com.apple.security.hypervisor": true] as NSDictionary, "its own, less debugging")
        XCTAssertEqual(signing.entitlementsGiven("Tool.app/Contents/Frameworks/Kit.framework/Versions/A/Helpers/kit-tool"),
                       ["com.apple.security.cs.allow-jit": true] as NSDictionary)
        XCTAssertNil(signing.entitlementsGiven("Tool.app/Contents/Helpers/lib/x.dylib"))
        XCTAssertNil(signing.entitlementsGiven("Tool.app/Contents/Frameworks/Kit.framework"))
        XCTAssertEqual(signing.entitlementsGiven("Tool.app"), ["com.apple.security.virtualization": true] as NSDictionary)
        let entries = String(decoding: try ProcessRunner.run("/usr/bin/unzip", ["-Z1", zip.path]), as: UTF8.self)
        XCTAssertTrue(entries.contains("Tool.app/Contents/Resources/tool/firmware.fd"), "zipped again")
        let firmware = try ProcessRunner.run("/usr/bin/unzip", ["-p", zip.path, "Tool.app/Contents/Resources/tool/firmware.fd"])
        XCTAssertEqual(firmware, Data("firmware".utf8), "left as it was")
    }

    /// Mach-O is told by its first bytes: thin and universal, 32- and
    /// 64-bit, either byte order; not by a name, nor a Java class file's
    /// bytes (which begin as a universal binary's do), a script or a file
    /// too short to say.
    func testMachOIsToldByItsFirstBytes() throws {
        let folder = TestIPA.folder()
        func file(_ bytes: [UInt8], named name: String = UUID().uuidString) throws -> URL {
            let file = folder.appendingPathComponent(name)
            try Data(bytes).write(to: file)
            return file
        }
        let padding = [UInt8](repeating: 0, count: 24)
        for head: [UInt8] in [[0xFE, 0xED, 0xFA, 0xCE, 0, 0, 0, 7], [0xCE, 0xFA, 0xED, 0xFE, 7, 0, 0, 0],
                              [0xFE, 0xED, 0xFA, 0xCF, 1, 0, 0, 7], [0xCF, 0xFA, 0xED, 0xFE, 12, 0, 0, 1],
                              [0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2], [0xBE, 0xBA, 0xFE, 0xCA, 2, 0, 0, 0],
                              [0xCA, 0xFE, 0xBA, 0xBF, 0, 0, 0, 1], [0xBF, 0xBA, 0xFE, 0xCA, 1, 0, 0, 0]] {
            XCTAssertTrue(Signer.isMachO(try file(head + padding)), "\(head)")
        }
        XCTAssertTrue(Signer.isMachO(URL(fileURLWithPath: "/usr/bin/true")))
        XCTAssertFalse(Signer.isMachO(try file([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 0x34] + padding)), "a Java 8 class file")
        XCTAssertFalse(Signer.isMachO(try file(Array("#!/bin/sh\nexit 0\n".utf8), named: "libx.dylib")))
        XCTAssertFalse(Signer.isMachO(try file([0xCF, 0xFA, 0xED])))
    }

    /// The notary says it notarized nothing (no key here): the app is
    /// signed, not stapled, and published.
    func testNotarizationIsSkippedWhenTheNotarySaysSo() throws {
        let folder = TestIPA.folder()
        let signing = FakeCodeSigning()
        let skipping = FakeNotary(accepts: false, events: signing.events)
        let result = try signer(signing, profiles: folder.appendingPathComponent("profiles"), notary: skipping).sign(macZip: try macZip(in: folder))
        XCTAssertEqual(result, .skipped("the fake notarizes nothing"))
        XCTAssertEqual(signing.events.all.last, "notarize")
        XCTAssertFalse(signing.events.all.contains { $0.hasPrefix("staple") })
        XCTAssertEqual(signing.signed.count, 3)
        // With no Developer ID identity here, it is refused before signing.
        let none = FakeCodeSigning(identities: TestProfile.identities.filter { $0.kind != .developerID })
        XCTAssertThrowsError(try signer(none, profiles: folder.appendingPathComponent("profiles")).sign(macZip: try macZip(in: folder))) { error in
            XCTAssertTrue("\(error)".hasPrefix("No Developer ID Application identity"), "\(error)")
        }
        XCTAssertEqual(none.signed, [])
    }
}
