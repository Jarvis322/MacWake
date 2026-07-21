import AppKit
import Foundation

struct AppLanguage: Identifiable, Hashable {
    let id: String
    let displayName: String
}

enum AppLanguagePreference {
    private static let appleLanguagesKey = "AppleLanguages"

    static let supportedLanguages: [AppLanguage] = Array(Set(Bundle.main.localizations))
        .filter { $0 != "Base" }
        .sorted()
        .map { identifier in
            let locale = Locale(identifier: identifier)
            return AppLanguage(
                id: identifier,
                displayName: locale.localizedString(forIdentifier: identifier) ?? identifier
            )
        }

    static var selectedLanguageIdentifier: String? {
        guard
            let bundleIdentifier = Bundle.main.bundleIdentifier,
            let appDomain = UserDefaults.standard.persistentDomain(forName: bundleIdentifier),
            let storedIdentifier = (appDomain[appleLanguagesKey] as? [String])?.first
        else {
            return nil
        }

        let supported = supportedLanguages
        let normalizedStored = storedIdentifier.replacingOccurrences(of: "_", with: "-").lowercased()
        if let exact = supported.first(where: { $0.id.lowercased() == normalizedStored }) {
            return exact.id
        }

        if let regionalMatch = supported.first(where: {
            let candidate = $0.id.lowercased()
            return normalizedStored.hasPrefix(candidate + "-") || candidate.hasPrefix(normalizedStored + "-")
        }) {
            return regionalMatch.id
        }

        let storedLanguageCode = Locale(identifier: storedIdentifier).language.languageCode?.identifier
        let languageMatches = supported.filter {
            Locale(identifier: $0.id).language.languageCode?.identifier == storedLanguageCode
        }
        return languageMatches.count == 1 ? languageMatches[0].id : nil
    }

    static func select(_ identifier: String?) {
        if let identifier {
            UserDefaults.standard.set([identifier], forKey: appleLanguagesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: appleLanguagesKey)
        }
        // The next process reads this during Bundle initialization, so flush before a
        // possible immediate restart instead of relying on the normal deferred write.
        UserDefaults.standard.synchronize()
    }

    /// Starts a short-lived helper that waits for this process to finish before asking
    /// Launch Services to reopen the same bundle. Waiting avoids racing the single-instance
    /// guard in MacWakeApp.init().
    @MainActor
    static func restart() -> Bool {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            """
            pid="$1"
            bundle="$2"
            attempts=0
            while kill -0 "$pid" 2>/dev/null; do
                attempts=$((attempts + 1))
                [ "$attempts" -ge 100 ] && exit 1
                sleep 0.1
            done
            exec /usr/bin/open "$bundle"
            """,
            "macwake-relaunch",
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundleURL.path
        ]

        do {
            try helper.run()
        } catch {
            print("Failed to schedule MacWake restart: \(error)")
            return false
        }

        NSApplication.shared.terminate(nil)
        return true
    }
}
