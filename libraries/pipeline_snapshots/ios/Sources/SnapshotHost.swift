import SwiftUI
import UIKit

/// A view in a window of a device's size (never key, never shown to anyone
/// but the test), with the traits it is given (a phone's compact width, an
/// iPad's regular one), settled and drawn.
@MainActor
public final class SnapshotHost {
    public let window: UIWindow
    public let controller: UIViewController

    public init(_ view: some View, size: CGSize, regular: Bool) {
        let controller = UIHostingController(rootView: AnyView(view))
        controller.traitOverrides.horizontalSizeClass = regular ? .regular : .compact
        controller.traitOverrides.verticalSizeClass = .regular
        controller.traitOverrides.userInterfaceStyle = .light
        // In the app's scene (a window in none never draws), the size asked
        // for whatever the simulator's screen.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.isHidden = false
        self.window = window
        self.controller = controller
        settle()
    }

    /// Lets SwiftUI and UIKit lay out and draw (tasks, transitions).
    public func settle(_ seconds: TimeInterval = 0.6) {
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        window.layoutIfNeeded()
    }

    /// The window's layers as they draw, at 2x whatever the device (the
    /// layers themselves, so a window larger than the simulator's screen
    /// draws whole; materials draw as their plain colour).
    public func picture() -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            UIColor.systemBackground.setFill()
            context.fill(window.bounds)
            window.layer.render(in: context.cgContext)
        }
        // A renderer's image always has its CGImage.
        return image.cgImage!
    }

    /// A kept picture in an iOS test's bundle.
    public static func kept(_ name: String, in bundle: Bundle) -> URL? { bundle.url(forResource: name, withExtension: "png") }

    /// Lets the window go (a test's hosts must not pile up in the scene).
    public func close() {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// The split view's columns' titles, as their navigation bars show
    /// them: the sidebar's and the detail's (nil where there is no split
    /// view, or no such column).
    public func columnTitles() -> (sidebar: String?, detail: String?) {
        func split(_ controller: UIViewController) -> UISplitViewController? {
            if let found = controller as? UISplitViewController { return found }
            // In tabs: the tab shown's.
            if let tabs = controller as? UITabBarController, let shown = tabs.selectedViewController { return split(shown) }
            for child in controller.children { if let found = split(child) { return found } }
            return nil
        }
        func title(_ controller: UIViewController?) -> String? {
            guard let controller else { return nil }
            var deepest = controller
            while let navigation = deepest as? UINavigationController, let top = navigation.topViewController { deepest = top }
            if let shown = deepest.navigationItem.title { return shown }
            for child in deepest.children { if let found = title(child) { return found } }
            return deepest.navigationController?.navigationBar.topItem?.title ?? ""
        }
        guard let split = split(controller) else { return (nil, nil) }
        return (title(split.viewController(for: .primary)), title(split.viewController(for: .secondary)))
    }

    /// The title the navigation bar showing says (a phone's one column).
    public func shownTitle() -> String? {
        var found: String?
        func walk(_ view: UIView) {
            if found == nil, let bar = view as? UINavigationBar, !bar.isHidden, bar.window != nil, bar.frame.height > 0 { found = bar.topItem?.title }
            for sub in view.subviews { walk(sub) }
        }
        walk(window)
        return found
    }

    /// The widest a list or a form (a collection or table view) reaches
    /// past the window's right edge: a sheet asked to be wider than the
    /// screen ran off it.
    public func listOverflow() -> CGFloat {
        var most: CGFloat = 0
        func walk(_ view: UIView) {
            if view is UICollectionView || view is UITableView {
                most = max(most, view.convert(view.bounds, to: nil).maxX - window.bounds.width)
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(window)
        return most
    }

    /// Scrolls every view that scrolls sideways (one wider than it is
    /// shown) by `x` points, as a finger would, and lets it settle: what
    /// stays put while it scrolls is seen in the picture after.
    public func scrollSideways(by x: CGFloat) {
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1 {
                scroll.setContentOffset(CGPoint(x: min(x, scroll.contentSize.width - scroll.bounds.width), y: scroll.contentOffset.y),
                                       animated: false)
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(window)
        settle()
    }
}
