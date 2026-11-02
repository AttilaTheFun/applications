#if canImport(Darwin)
import Foundation

/// A Darwin notification in the app group's name, which every process of
/// the group can post and hear: the database changed (Applications synced a
/// newer build, an app asked Applications to install one). It carries
/// nothing; whoever hears it reads the database. No URL schemes, no XPC.
public struct UpdateSignal: Sendable {
    public let name: String

    public init(appGroup: String = AppGroupStore.applicationsAppGroup) {
        name = appGroup + ".updates"
    }

    public func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }

    /// Each time it is posted (by any process, this one too), until the
    /// sequence is dropped.
    public func changes() -> AsyncStream<Void> {
        let name = self.name
        return AsyncStream { continuation in
            let observer = SignalObserver(continuation: continuation)
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(observer).toOpaque(),
                                            { _, observer, _, _, _ in
                                                guard let observer else { return }
                                                Unmanaged<SignalObserver>.fromOpaque(observer).takeUnretainedValue().continuation.yield()
                                            }, name as CFString, nil, .deliverImmediately)
            // The observer lives as long as this closure, which the stream
            // keeps until it ends.
            continuation.onTermination = { _ in
                CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(observer).toOpaque(),
                                                   CFNotificationName(name as CFString), nil)
            }
        }
    }
}

/// What a Darwin notification's callback is handed: the stream to tell.
private final class SignalObserver: Sendable {
    let continuation: AsyncStream<Void>.Continuation

    init(continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }
}
#endif
