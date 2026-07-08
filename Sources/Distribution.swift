import Foundation

/// Which distribution this binary was built for. The App Store variant is compiled with
/// `-DAPPSTORE` (see build-appstore.sh): it is sandboxed, ships no privileged helper, no
/// Sparkle, no CLI, and hides every feature that depends on them. One codebase, two builds.
enum Distribution {
    #if APPSTORE
    static let isAppStore = true
    #else
    static let isAppStore = false
    #endif
}
