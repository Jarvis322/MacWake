import AppKit
import SwiftUI

/// Temporarily blocks keyboard and trackpad/mouse input system-wide so wiping the screen
/// or keyboard doesn't type garbage or trigger clicks — the same idea as Apple's built-in
/// "lock keyboard and screen for cleaning" gesture, or third-party KeyboardCleanTool-style
/// utilities. Implemented with a CGEventTap, which requires Accessibility permission.
///
/// Safety properties this is built around, since a bug here could make the Mac briefly
/// unusable:
/// - A hard-capped duration (`maxDurationSeconds`) regardless of what's requested.
/// - Holding Escape for `escapeHoldThreshold` seconds cancels immediately — checked
///   INSIDE the tap callback itself, since once the tap is active no other code path can
///   react to input at all.
/// - `.tapDisabledByTimeout`/`.tapDisabledByUserInput` (the system's own safety valve for
///   an unresponsive tap) re-enables the tap rather than silently losing the block or
///   leaving stale state.
/// - Explicit teardown on app termination (see AppDelegate.applicationWillTerminate) in
///   addition to the timer, so a graceful quit while active can't leave input blocked.
@MainActor
final class CleaningModeManager: ObservableObject {
    static let shared = CleaningModeManager()

    @Published private(set) var isActive = false
    @Published private(set) var remainingSeconds: Int = 0

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var countdownTimer: Timer?
    private var overlayWindows: [NSWindow] = []
    private var escapeHoldStart: Date?
    private let escapeHoldThreshold: TimeInterval = 1.5
    let maxDurationSeconds = 120

    private init() {}

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the system Accessibility permission dialog if not already granted. The
    /// user must re-trigger `start` themselves after granting it — permission changes
    /// take effect immediately, no relaunch needed.
    func requestAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start(durationSeconds: Int) {
        guard !isActive else { return }
        guard hasAccessibilityPermission else {
            requestAccessibilityPermission()
            return
        }
        guard installEventTap() else { return }   // never claim active without a working tap

        isActive = true
        remainingSeconds = min(max(durationSeconds, 10), maxDurationSeconds)
        escapeHoldStart = nil
        showOverlay()

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        remainingSeconds -= 1
        if remainingSeconds <= 0 { stop() }
    }

    func stop() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        removeEventTap()
        hideOverlay()
        escapeHoldStart = nil
        isActive = false
    }

    // MARK: - Event Tap

    private func installEventTap() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: cleaningModeTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func removeEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Called synchronously from the tap callback (main thread — the run loop source is
    /// attached to CFRunLoopGetMain()). Must return quickly. Returning nil swallows the
    /// event entirely; every path here returns nil except the tap-disabled recovery path.
    fileprivate func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }

        if type == .keyDown || type == .keyUp {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 53 { // Escape
                if type == .keyDown {
                    if escapeHoldStart == nil { escapeHoldStart = Date() }
                    if let start = escapeHoldStart, Date().timeIntervalSince(start) >= escapeHoldThreshold {
                        stop()
                    }
                } else {
                    escapeHoldStart = nil
                }
            }
        }

        return nil
    }

    // MARK: - Overlay

    private func showOverlay() {
        overlayWindows = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.contentView = NSHostingView(rootView: CleaningOverlayView(manager: self))
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            return window
        }
    }

    private func hideOverlay() {
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
    }
}

/// A plain C function pointer (no captures) — CGEventTap's callback can't be a Swift
/// closure that captures context. `refcon` carries the manager instance instead.
/// `MainActor.assumeIsolated` is safe here because the run loop source is attached to
/// CFRunLoopGetMain(), so this always actually runs on the main thread.
private let cleaningModeTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passRetained(event) }
    return MainActor.assumeIsolated {
        let manager = Unmanaged<CleaningModeManager>.fromOpaque(refcon).takeUnretainedValue()
        return manager.handleTapEvent(type: type, event: event)
    }
}

struct CleaningOverlayView: View {
    @ObservedObject var manager: CleaningModeManager

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "hand.raised.slash.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundColor(.white)
            Text(String(localized: "Cleaning Mode"))
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
            Text(String(format: String(localized: "CLEANING_SECONDS_FMT"), manager.remainingSeconds))
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.75))
                .monospacedDigit()
            Text(String(localized: "Keyboard and trackpad input is paused. Hold Escape for 1.5s to unlock early."))
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.45))
    }
}
