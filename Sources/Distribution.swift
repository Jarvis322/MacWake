import Foundation

/// Which distribution this binary was built for. The App Store variant is compiled with
/// `-DAPPSTORE` (see build-appstore.sh): it is sandboxed, ships no privileged helper, no
/// Sparkle, no CLI, and hides every feature that depends on them. One codebase, two builds.
enum Distribution {
    #if APPSTORE
    static let isAppStore = true
    /// App Store requires a portal-registered group, and the portal only accepts the
    /// "group." prefix.
    static let appGroupID = "group.com.jarvisit.macwake"
    #else
    static let isAppStore = false
    /// Team-prefixed legacy style: auto-authorized for same-team Developer ID apps with
    /// no portal registration and no Sequoia consent prompt.
    static let appGroupID = "6NK6D7LL79.com.jarvisit.macwake"
    #endif
}
