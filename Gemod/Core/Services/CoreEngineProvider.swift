import Foundation

enum CoreEngineProvider {
    static func makeEngine() -> CoreEngine {
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return SingboxMockEngine()
        }
        return SingboxRealEngine()
    }
}
