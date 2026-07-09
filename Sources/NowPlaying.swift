#if !APPSTORE
import Foundation
import AppKit

struct NowPlayingInfo: Equatable {
    var app: MusicApp
    var title: String
    var artist: String
    var isPlaying: Bool
    var artworkURL: String?   // Spotify only; Music artwork comes as raw data

    /// Identity of the *track* (not play state) — used to know when to refetch artwork.
    var trackKey: String { "\(app.rawValue)|\(title)|\(artist)" }
}

enum MusicApp: String {
    case spotify = "Spotify"
    case music = "Music"

    var processName: String { rawValue }
    var displayName: String { self == .spotify ? "Spotify" : "Apple Music" }
}

/// Reads the current track and drives playback for Spotify and Apple Music via AppleScript.
/// GitHub (Developer ID) build only — the sandboxed App Store build can't send Apple Events
/// to other apps without a reviewed entitlement exception, so this whole file is compiled out.
///
/// AppleScript runs IN-PROCESS (NSAppleScript), not via an osascript subprocess, so macOS
/// attributes the Automation permission prompt to MacWake ("MacWake wants to control
/// Spotify"), and the granted permission belongs to us — a subprocess would misattribute it.
@MainActor
final class NowPlayingManager: ObservableObject {
    static let shared = NowPlayingManager()

    @Published private(set) var info: NowPlayingInfo?
    @Published private(set) var artwork: NSImage?

    @Published var isEnabled: Bool = UserDefaults.standard.bool(forKey: "enableNowPlaying") {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "enableNowPlaying")
            isEnabled ? start() : stop()
        }
    }

    private var timer: Timer?
    private let queue = DispatchQueue(label: "com.jarvisit.macwake.nowplaying", qos: .utility)
    private var isPolling = false
    private var lastArtworkTrackKey: String?

    private init() {
        if isEnabled { start() }
    }

    private func start() {
        poll()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        info = nil
        artwork = nil
        lastArtworkTrackKey = nil
    }

    // MARK: - Polling

    private func poll() {
        guard !isPolling else { return }
        isPolling = true
        queue.async { [weak self] in
            let parsed = Self.runReadScript()
            Task { @MainActor in
                guard let self else { return }
                self.isPolling = false
                self.apply(parsed)
            }
        }
    }

    private func apply(_ new: NowPlayingInfo?) {
        if info != new { info = new }
        guard let new else { artwork = nil; lastArtworkTrackKey = nil; return }
        // Refetch artwork only when the track itself changes.
        if new.trackKey != lastArtworkTrackKey {
            lastArtworkTrackKey = new.trackKey
            fetchArtwork(for: new)
        }
    }

    // MARK: - Read (which app + track)

    /// Reads Spotify and Music with SEPARATE scripts. A single combined script would fail
    /// to compile if EITHER app isn't installed (its AppleScript terminology can't be
    /// resolved), silently hiding the other. Each app is queried only when it's actually
    /// running (checked via NSRunningApplication so we never launch it). Spotify wins ties.
    nonisolated private static func runReadScript() -> NowPlayingInfo? {
        let spotify = isRunning("com.spotify.client") ? readSpotify() : nil
        let music = isRunning("com.apple.Music") ? readMusic() : nil
        if let spotify, spotify.isPlaying { return spotify }
        if let music, music.isPlaying { return music }
        return spotify ?? music   // whichever is paused
    }

    nonisolated private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    nonisolated private static func readSpotify() -> NowPlayingInfo? {
        let source = """
        tell application "Spotify"
            set theState to player state as string
            return theState & "|" & (name of current track) & "|" & (artist of current track) & "|" & (artwork url of current track)
        end tell
        """
        return parse(runAppleScript(source), app: .spotify)
    }

    nonisolated private static func readMusic() -> NowPlayingInfo? {
        let source = """
        tell application "Music"
            set theState to player state as string
            return theState & "|" & (name of current track) & "|" & (artist of current track)
        end tell
        """
        return parse(runAppleScript(source), app: .music)
    }

    nonisolated private static func parse(_ raw: String?, app: MusicApp) -> NowPlayingInfo? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "|")
        guard parts.count >= 3 else { return nil }
        let state = parts[0]
        guard state == "playing" || state == "paused" else { return nil }
        let url = parts.count >= 4 ? parts[3] : ""
        return NowPlayingInfo(
            app: app,
            title: parts[1],
            artist: parts[2],
            isPlaying: state == "playing",
            artworkURL: url.isEmpty ? nil : url
        )
    }

    // MARK: - Artwork

    private func fetchArtwork(for info: NowPlayingInfo) {
        let key = info.trackKey
        switch info.app {
        case .spotify:
            guard let urlString = info.artworkURL, let url = URL(string: urlString) else { artwork = nil; return }
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                let image = data.flatMap { NSImage(data: $0) }
                Task { @MainActor in
                    guard let self, self.lastArtworkTrackKey == key else { return }
                    self.artwork = image
                }
            }.resume()
        case .music:
            queue.async { [weak self] in
                let image = Self.musicArtwork()
                Task { @MainActor in
                    guard let self, self.lastArtworkTrackKey == key else { return }
                    self.artwork = image
                }
            }
        }
    }

    /// Apple Music artwork comes as raw picture data — dump it to a temp file and load it.
    nonisolated private static func musicArtwork() -> NSImage? {
        let path = NSTemporaryDirectory() + "macwake-artwork.dat"
        let source = """
        tell application "Music"
            if player state is stopped then return "no"
            try
                set d to raw data of artwork 1 of current track
            on error
                return "no"
            end try
        end tell
        set f to open for access (POSIX file "\(path)") with write permission
        set eof f to 0
        write d to f
        close access f
        return "ok"
        """
        guard runAppleScript(source) == "ok" else { return nil }
        return NSImage(contentsOfFile: path)
    }

    // MARK: - Controls

    func playPause() { sendCommand("playpause") }
    func next() { sendCommand("next track") }
    func previous() { sendCommand("previous track") }

    private func sendCommand(_ command: String) {
        guard let app = info?.app else { return }
        queue.async { [weak self] in
            _ = Self.runAppleScript("tell application \"\(app.rawValue)\" to \(command)")
            // Reflect the change quickly instead of waiting for the next 3s tick.
            Task { @MainActor in self?.poll() }
        }
    }

    // MARK: - AppleScript

    nonisolated private static func runAppleScript(_ source: String) -> String? {
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&err)
        if err != nil { return nil }
        return result.stringValue
    }
}

// MARK: - Dynamic Island column

import SwiftUI

struct NowPlayingView: View {
    @ObservedObject private var np = NowPlayingManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: np.info?.app == .spotify ? "music.note" : "music.note.list")
                    .font(.system(size: 8, weight: .bold))
                Text((np.info?.app.displayName ?? "").uppercased())
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundColor(.white.opacity(0.4))

            HStack(spacing: 10) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    Text(np.info?.title ?? "")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1).truncationMode(.tail)
                    Text(np.info?.artist ?? "")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1).truncationMode(.tail)
                }
            }

            HStack(spacing: 14) {
                controlButton("backward.fill", size: 12) { np.previous() }
                controlButton(np.info?.isPlaying == true ? "pause.fill" : "play.fill", size: 15) { np.playPause() }
                controlButton("forward.fill", size: 12) { np.next() }
                Spacer(minLength: 0)
            }
            .padding(.top, 1)
        }
        .frame(width: 190, alignment: .leading)
    }

    @ViewBuilder
    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.white.opacity(0.08))
            if let art = np.artwork {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
        .frame(width: 46, height: 46)
    }

    private func controlButton(_ icon: String, size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.12))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
#endif
