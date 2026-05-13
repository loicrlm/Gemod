import Foundation

enum AppLanguage {
    static var useSimplifiedChinese: Bool {
        guard let preferred = Locale.preferredLanguages.first?.lowercased() else {
            return false
        }
        return preferred.hasPrefix("zh-hans") || preferred.hasPrefix("zh-hant") || preferred.hasPrefix("zh")
    }
}
