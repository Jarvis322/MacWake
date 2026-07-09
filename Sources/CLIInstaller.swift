#if !APPSTORE
import Foundation

/// Installs/removes the embedded `macwake` command-line tool by symlinking it into
/// /usr/local/bin. Writing there needs root, so we use a single administrator prompt.
enum CLIInstaller {
    static let linkPath = "/usr/local/bin/macwake"

    static var embeddedPath: String {
        Bundle.main.bundlePath + "/Contents/Helpers/macwake"
    }

    static var isInstalled: Bool {
        // Installed only if the symlink resolves to *our* embedded tool. If something
        // else occupies linkPath (a regular file from another tool/package manager), we
        // are NOT "installed" — surfacing that lets Settings offer Install instead of
        // silently overwriting an unrelated file the next time install() runs.
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath) else {
            return false
        }
        return dest == embeddedPath
    }

    @discardableResult
    static func install() -> Bool {
        runAdmin("mkdir -p /usr/local/bin && ln -sf '\(embeddedPath)' '\(linkPath)'")
    }

    @discardableResult
    static func uninstall() -> Bool {
        runAdmin("rm -f '\(linkPath)'")
    }

    private static func runAdmin(_ shell: String) -> Bool {
        let escaped = shell.replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
        return err == nil
    }
}

#endif
