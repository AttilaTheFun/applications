import Foundation

/// Installs an update the way its platform does:
/// - with an update handler (a Mac app that restarts itself), the handler;
/// - on an iPhone or an iPad, the build's over-the-air install link opened
///   (iOS asks, then ends the app and replaces it);
/// - on a Mac, an install request written to the shared database,
///   Applications opened (or told, if it runs), and the app quit; it is
///   opened again once the build is in place.
public struct UpdateInstaller: Sendable {
    public let store: AppGroupStore
    public let system: any UpdateSystem
    public let platform: UpdatePlatform
    public let handler: UpdateHandler?
    /// The app asking: its own bundle id.
    public let requester: String
    private let now: @Sendable () -> Date

    public init(store: AppGroupStore, system: any UpdateSystem, platform: UpdatePlatform = .current, handler: UpdateHandler?,
                requester: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.system = system
        self.platform = platform
        self.handler = handler
        self.requester = requester
        self.now = now
    }

    public func install(_ update: AvailableUpdate) async throws -> InstallOutcome {
        if let handler {
            try await handler(update)
            return .handled
        }
        switch platform {
        case .iOS:
            guard let url = update.installURL else { throw UpdateInstallError.noInstallURL }
            guard await system.open(url) else { throw UpdateInstallError.installLinkRefused }
            return .openedInstallLink
        case .macOS:
            try await store.requestInstall(InstallRequest(bundleID: update.bundleID, version: update.version, build: update.build,
                                                          requestedBy: requester, requestedAt: now()))
            await system.databaseChanged()
            do {
                try await system.openApplications()
            } catch {
                try? await store.cancelInstallRequest(bundleID: update.bundleID)
                throw error
            }
            await system.terminate()
            return .askedApplications
        }
    }
}
