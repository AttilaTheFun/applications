import ApplicationUpdates

/// Notifications as a test sees them: whether the app is in front, and what
/// it was told.
actor FakePresenter: UpdatePresenter {
    var foreground = true
    private(set) var presented: [AvailableUpdate] = []

    func setForeground(_ value: Bool) { foreground = value }
    func isInForeground() async -> Bool { foreground }
    func present(_ update: AvailableUpdate) async { presented.append(update) }
}
