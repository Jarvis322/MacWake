import Foundation
#if !APPSTORE
import TelemetryDeck
#endif

/// Thin wrapper around TelemetryDeck so analytics compiles completely out of the
/// sandboxed App Store build — that binary ships with no third-party analytics library.
enum Analytics {
    static func initialize() {
        #if !APPSTORE
        let config = TelemetryDeck.Config(appID: "47BC5AD6-3456-4A13-97F3-10C169BFDAD6")
        TelemetryDeck.initialize(config: config)
        #endif
    }

    static func signal(_ name: String, parameters: [String: String] = [:]) {
        #if !APPSTORE
        TelemetryDeck.signal(name, parameters: parameters)
        #endif
    }
}
