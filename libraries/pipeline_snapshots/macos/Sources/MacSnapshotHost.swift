import AppKit
import SwiftUI
import XCTest

/// A view in a Mac window of the size asked for, never shown (never ordered
/// in, so nothing appears on anyone's screen), settled and drawn; and the
/// window's title, which a split view takes from its detail.
@MainActor
public final class MacSnapshotHost {
    public let window: NSWindow

    public init(_ view: some View, size: CGSize) {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = NSHostingController(rootView: AnyView(view))
        window.setContentSize(size)
        settle()
    }

    public func settle(_ seconds: TimeInterval = 0.5) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    public var title: String { window.title }

    /// The window's content as it draws, at 1x whatever the display's
    /// scale (a window never shown draws at 1x; said here so every Mac
    /// draws the same).
    public func picture() -> CGImage? {
        guard let view = window.contentView,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    /// The window as its kept picture, where a Mac draws it as the kept
    /// ones were: where CI or SNAPSHOT_COMPARE=1 says so (GitHub's Mac,
    /// which the kept pictures are from, or a test VM's login session). A
    /// shell outside a login session, and a headless Mac's self-hosted
    /// runner, draw a window's lists blank, so there it is not compared
    /// (the window's title still is); recording (SNAPSHOT_RECORD_DIR)
    /// always is.
    public func check(_ name: String, package: String, file: StaticString = #filePath, line: UInt = #line) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CI"] != nil || environment["SNAPSHOT_COMPARE"] == "1" || environment["SNAPSHOT_RECORD_DIR"] != nil else { return }
        guard let picture = picture() else { return XCTFail("The window drew nothing", file: file, line: line) }
        Snapshot.check(picture, named: name, kept: Self.kept(name, package: package), file: file, line: line)
    }

    /// A kept picture in a Mac test's runfiles (its package's Snapshots/).
    public static func kept(_ name: String, package: String) -> URL? {
        guard let root = ProcessInfo.processInfo.environment["TEST_SRCDIR"] else { return nil }
        return URL(fileURLWithPath: root).appendingPathComponent("_main/\(package)/Snapshots/\(name).png")
    }
}
