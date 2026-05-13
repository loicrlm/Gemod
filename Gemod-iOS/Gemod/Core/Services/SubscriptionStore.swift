import Foundation

protocol SubscriptionStore {
    func load() -> SubscriptionState?
    func save(_ state: SubscriptionState) throws
}

final class UserDefaultsSubscriptionStore: SubscriptionStore {
    private let key = "gemod.single.subscription"
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> SubscriptionState? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }
        return try? decoder.decode(SubscriptionState.self, from: data)
    }

    func save(_ state: SubscriptionState) throws {
        let data = try encoder.encode(state)
        defaults.set(data, forKey: key)
    }
}
