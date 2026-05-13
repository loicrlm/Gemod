import Foundation

struct AppStateStore {
    private let defaults: UserDefaults
    private let snapshotKey = "gemod.snapshot"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSnapshot {
        guard let data = defaults.data(forKey: snapshotKey) else {
            return .empty
        }
        return (try? JSONDecoder().decode(AppSnapshot.self, from: data)) ?? .empty
    }

    func save(_ snapshot: AppSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        defaults.set(data, forKey: snapshotKey)
    }
}
