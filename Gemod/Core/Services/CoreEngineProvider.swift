import Foundation

enum CoreEngineProvider {
    // Phase 6: drive connection by system tunnel status.
    static let useRealSingboxEngine = true

    static func makeEngine() -> CoreEngine {
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return SingboxMockEngine()
        }
        if useRealSingboxEngine {
            return SingboxRealEngine()
        }
        return SingboxMockEngine()
    }
}
