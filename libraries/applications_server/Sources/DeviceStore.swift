import ApplicationsProtocol
import Foundation

/// The devices to tell of new builds: each one's push token, kept in
/// devices.json.
public struct DeviceStore: Sendable {
    let file: URL

    public init(file: URL) { self.file = file }

    public func all() -> [DeviceRegistration] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([DeviceRegistration].self, from: data)) ?? []
    }

    /// Keeps a device's token (again, when it registers again).
    public func register(_ device: DeviceRegistration) {
        var devices = all().filter { $0.token != device.token && !($0.name == device.name && $0.topic == device.topic) }
        devices.append(device)
        save(devices)
    }

    public func forget(token: String) { save(all().filter { $0.token != token }) }

    private func save(_ devices: [DeviceRegistration]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
