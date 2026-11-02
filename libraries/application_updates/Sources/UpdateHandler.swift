/// A Mac app's own way to update itself (OS Server, Visor Runner and
/// Applications Server, which must stop their work in order): given the
/// update, whose `installURL` is the build's .zip, it installs it and
/// restarts the app. Registered with `AppUpdates.register(updateHandler:)`.
public typealias UpdateHandler = @Sendable (AvailableUpdate) async throws -> Void
