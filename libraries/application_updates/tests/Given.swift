import ApplicationUpdates

/// What an update handler was given.
actor Given {
    private(set) var update: AvailableUpdate?

    func set(_ update: AvailableUpdate) { self.update = update }
}
