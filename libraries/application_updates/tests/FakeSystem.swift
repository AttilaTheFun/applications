import ApplicationUpdates
import Foundation

/// The system as a test sees it: what was asked of it, in order.
actor FakeSystem: UpdateSystem {
    private(set) var events: [String] = []
    var opensURLs = true
    var hasApplications = true

    func setOpensURLs(_ value: Bool) { opensURLs = value }
    func setHasApplications(_ value: Bool) { hasApplications = value }

    func open(_ url: URL) async -> Bool {
        events.append("open \(url.absoluteString)")
        return opensURLs
    }

    func openApplications() async throws {
        guard hasApplications else { throw UpdateInstallError.applicationsNotInstalled }
        events.append("open Applications")
    }

    func terminate() async { events.append("terminate") }

    func databaseChanged() async { events.append("changed") }
}
