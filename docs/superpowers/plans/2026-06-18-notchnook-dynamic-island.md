# NotchNook-Style Dynamic Island Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace click-to-expand Dynamic Island with hover-activated panel featuring debounced open/close, two-column expanded layout (power left, thermals right), and English strings throughout.

**Architecture:** `NSTrackingArea` installed on the panel's `contentView` forwards `mouseEntered`/`mouseExited` to `DynamicIslandManager`, which uses two `DispatchWorkItem` debounce timers (150ms open, 300ms close). The SwiftUI view is rebuilt with a left power widget and right thermals widget. A small `temperatureSamples` ring buffer (last 5 readings, sampled alongside existing heartbeat) is added to `BatteryTracker` to power the mini bar chart.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit (NSPanel, NSTrackingArea), IOKit, Combine

## Global Constraints

- macOS 14.0+ minimum
- No new Swift Package dependencies
- All user-visible strings in English
- Build must pass with `DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer" swift build -c release` with zero errors
- Do NOT remove `.charging` or `.alert` state logic — only hover replaces click for `.expanded`

---

### Task 1: Add temperature sample buffer to BatteryTracker

**Files:**
- Modify: `Sources/BatteryTracker.swift`

**Interfaces:**
- Produces: `@Published var temperatureSamples: [Double]` — array of up to 5 recent `batteryTemperature` readings, newest last. Read by `DynamicIslandPanelView` right widget.

- [ ] **Step 1: Add the published property**

In `BatteryTracker`, after the `@Published var batteryTemperature: Double = 0.0` line (line ~26), add:

```swift
@Published var temperatureSamples: [Double] = []
```

- [ ] **Step 2: Populate it in the heartbeat / temperature update path**

Find the method `updateHeartbeat` or wherever `batteryTemperature` is assigned (search for `batteryTemperature =`). After every assignment to `batteryTemperature`, append the value and cap at 5:

```swift
self.batteryTemperature = temp  // existing line
// append sample
self.temperatureSamples.append(temp)
if self.temperatureSamples.count > 5 {
    self.temperatureSamples.removeFirst()
}
```

Do this for every place `batteryTemperature` is written (there may be 1-2 sites). Search with:
```bash
grep -n "batteryTemperature =" Sources/BatteryTracker.swift
```

- [ ] **Step 3: Persist/restore — skip (ephemeral is fine)**

The samples are rebuilt within seconds of launch from the heartbeat. No persistence needed.

- [ ] **Step 4: Build to verify no errors**

```bash
DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer" swift build 2>&1 | grep -E "error:|warning:"
```

Expected: only the existing `notchH` unused-variable warning. Zero new errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/BatteryTracker.swift
git commit -m "feat: add temperatureSamples ring buffer to BatteryTracker"
```

---

### Task 2: Rewrite DynamicIslandPanelView with hover + new layout

**Files:**
- Modify: `Sources/DynamicIslandWindow.swift`

**Interfaces:**
- Consumes: `BatteryTracker.temperatureSamples: [Double]`, `BatteryTracker.currentFanSpeed: Double?`, `BatteryTracker.hasFans: Bool`, `BatteryTracker.dynamicWatts: Double?`, `BatteryTracker.powerAdapterWatts: Int?`, `BatteryTracker.powerAdapterName: String?`, `BatteryTracker.currentSession: Session?`, `BatteryTracker.appState: String`, `BatteryTracker.lastStateChange: Date` (private — expose via computed `var screenOnSeconds: TimeInterval` added in Task 1 if needed, or replicate `menuBarText` logic)
- Produces: Updated `DynamicIslandPanelView` struct; `DynamicIslandManager` gains `hoverDidEnter()` / `hoverDidExit()` public methods

**Note on screen time:** `lastStateChange` is `private` in `BatteryTracker`. Add a computed property to expose session screen-on duration:

In `BatteryTracker` (Task 2 prerequisite, add now):
```swift
var currentScreenOnSeconds: TimeInterval {
    guard let session = currentSession else { return 0 }
    let delta = appState == "active" ? Date().timeIntervalSince(lastStateChange) : 0
    return session.screenOnDuration + delta
}
```

- [ ] **Step 1: Add `currentScreenOnSeconds` to BatteryTracker**

Open `Sources/BatteryTracker.swift`. After `menuBarText` computed var (around line 1273), add:

```swift
var currentScreenOnSeconds: TimeInterval {
    guard let session = currentSession else { return 0 }
    let delta = appState == "active" ? Date().timeIntervalSince(lastStateChange) : 0
    return session.screenOnDuration + delta
}
```

- [ ] **Step 2: Add `hoverDidEnter()` / `hoverDidExit()` to DynamicIslandManager**

In `Sources/DynamicIslandWindow.swift`, inside `DynamicIslandManager`, add two properties and two methods. Place them after `private var localMonitor: Any?`:

```swift
private var expandWorkItem: DispatchWorkItem?
private var collapseWorkItem: DispatchWorkItem?

func hoverDidEnter() {
    collapseWorkItem?.cancel()
    collapseWorkItem = nil
    guard DynamicIslandStateManager.shared.state == .compact else { return }
    let work = DispatchWorkItem { [weak self] in
        guard self != nil else { return }
        Task { @MainActor in
            guard DynamicIslandStateManager.shared.state == .compact else { return }
            DynamicIslandStateManager.shared.show(.expanded)
        }
    }
    expandWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
}

func hoverDidExit() {
    expandWorkItem?.cancel()
    expandWorkItem = nil
    guard DynamicIslandStateManager.shared.state == .expanded else { return }
    let work = DispatchWorkItem { [weak self] in
        guard self != nil else { return }
        Task { @MainActor in
            guard DynamicIslandStateManager.shared.state == .expanded else { return }
            DynamicIslandStateManager.shared.show(.compact)
        }
    }
    collapseWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: work)
}
```

- [ ] **Step 3: Remove outside-click monitor, add NSTrackingArea setup**

Delete `setupClickMonitor()` method and its call in `buildWindow`. Replace with `setupHoverTracking()`:

```swift
private func setupHoverTracking() {
    guard let contentView = islandWindow?.contentView else { return }
    let area = NSTrackingArea(
        rect: contentView.bounds,
        options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: contentView,
        userInfo: nil
    )
    contentView.addTrackingArea(area)
}
```

Call `setupHoverTracking()` at the end of `buildWindow(for:)`, replacing the `setupClickMonitor()` call.

Also update `updateWindowFrame` — after `win.setFrame(...)`, call:
```swift
// Recreate tracking area to match new frame
if let cv = win.contentView {
    cv.trackingAreas.forEach { cv.removeTrackingArea($0) }
    let area = NSTrackingArea(
        rect: cv.bounds,
        options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: cv,
        userInfo: nil
    )
    cv.addTrackingArea(area)
}
```

- [ ] **Step 4: Forward NSView mouse events to DynamicIslandManager**

`NSHostingView` doesn't forward `mouseEntered`/`mouseExited` by default. Subclass it:

Add this class above `DynamicIslandManager`:

```swift
final class TrackingHostingView<Content: View>: NSHostingView<Content> {
    override func mouseEntered(with event: NSEvent) {
        DynamicIslandManager.shared.hoverDidEnter()
    }
    override func mouseExited(with event: NSEvent) {
        DynamicIslandManager.shared.hoverDidExit()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
```

In `buildWindow(for:)`, replace:
```swift
islandWindow?.contentView = NSHostingView(rootView: DynamicIslandPanelView(tracker: tracker))
```
with:
```swift
islandWindow?.contentView = TrackingHostingView(rootView: DynamicIslandPanelView(tracker: tracker))
```

- [ ] **Step 5: Remove tap gesture from DynamicIslandPanelView, update panelHeight**

In `DynamicIslandPanelView.body`, remove the `.onTapGesture { ... }` block entirely.

Update `panelHeight`:
```swift
private var panelHeight: CGFloat {
    switch sm.state {
    case .compact: return 36
    case .charging, .alert: return 120
    case .expanded: return 220
    }
}
```

- [ ] **Step 6: Rewrite expandedContent with two-column layout**

Replace the entire `expandedContent` computed var with:

```swift
private var expandedContent: some View {
    HStack(spacing: 20) {
        leftWidget
            .frame(maxWidth: .infinity, alignment: .leading)

        Rectangle()
            .fill(Color.white.opacity(0.1))
            .frame(width: 1)
            .padding(.vertical, 10)

        rightWidget
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

- [ ] **Step 7: Rewrite leftWidget (Power)**

Replace `leftWidget` with:

```swift
private var leftWidget: some View {
    HStack(spacing: 16) {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(
                    colors: [batteryColor.opacity(0.25), batteryColor.opacity(0.1)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 80, height: 80)
                .overlay(
                    Image(systemName: tracker.isPluggedIn ? "bolt.batteryblock.fill" : "battery.100")
                        .font(.system(size: 32))
                        .foregroundStyle(LinearGradient(
                            colors: [batteryColor.opacity(0.9), batteryColor],
                            startPoint: .top, endPoint: .bottom))
                )
            Circle()
                .fill(batteryColor)
                .frame(width: 24, height: 24)
                .overlay(
                    Image(systemName: tracker.isPluggedIn ? "bolt.fill" : "leaf.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.black)
                )
                .offset(x: 6, y: 6)
        }

        VStack(alignment: .leading, spacing: 6) {
            Text(tracker.isPluggedIn ? "Charging" : "On Battery")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
            Text("\(tracker.currentBatteryLevel)% Capacity")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            // Watt or adapter label
            if let dyn = tracker.dynamicWatts {
                Text(String(format: "%.1fW", dyn))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundColor(.cyan)
            } else if let w = tracker.powerAdapterWatts {
                Text("\(w)W Adapter")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.55))
            } else if let name = tracker.powerAdapterName {
                Text(name)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.45))
                    .lineLimit(1)
            }

            // Screen-on time (on battery only)
            if !tracker.isPluggedIn {
                let secs = Int(tracker.currentScreenOnSeconds)
                let h = secs / 3600
                let m = (secs % 3600) / 60
                Text(h > 0 ? "\(h)h \(m)m screen on" : "\(m)m screen on")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }
}
```

- [ ] **Step 8: Rewrite rightWidget (Thermals)**

Replace `rightWidget` with:

```swift
private var rightWidget: some View {
    VStack(alignment: .leading, spacing: 14) {
        // Fan RPM
        VStack(alignment: .leading, spacing: 2) {
            Text("Fan")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.4))
                .textCase(.uppercase)
            if tracker.hasFans, let rpm = tracker.currentFanSpeed {
                Text("\(Int(rpm)) RPM")
                    .font(.system(size: 22, weight: .bold).monospacedDigit())
                    .foregroundColor(.white)
            } else {
                Text("Fanless")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
            }
        }

        // Temperature mini bar chart
        VStack(alignment: .leading, spacing: 4) {
            Text("Temperature")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.4))
                .textCase(.uppercase)
            HStack(alignment: .bottom, spacing: 6) {
                let samples = tracker.temperatureSamples.isEmpty
                    ? [tracker.batteryTemperature]
                    : tracker.temperatureSamples
                let maxTemp = max(samples.max() ?? 1, 1)
                ForEach(Array(samples.enumerated()), id: \.offset) { _, temp in
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(temp > 45 ? Color.red.opacity(0.8) : Color.cyan.opacity(0.7))
                            .frame(width: 14, height: max(CGFloat(temp / maxTemp) * 40, 4))
                        Text(String(format: "%.0f°", temp))
                            .font(.system(size: 8))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            }
            .frame(height: 56, alignment: .bottom)
        }

        // Health + Cycles chips
        HStack(spacing: 8) {
            statChip(label: "Health", value: "\(tracker.batteryHealth)%", highlight: tracker.batteryHealth < 80)
            statChip(label: "Cycles", value: "\(tracker.batteryCycles)", highlight: false)
        }
    }
    .padding(.trailing, 10)
}

private func statChip(label: String, value: String, highlight: Bool) -> some View {
    VStack(spacing: 2) {
        Text(label)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(highlight ? .red : .white.opacity(0.4))
        Text(value)
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(highlight ? .red : .white)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(Color.white.opacity(0.08))
    .cornerRadius(8)
}
```

- [ ] **Step 9: Fix chargingContent English strings**

Replace `chargingContent`:

```swift
private var chargingContent: some View {
    HStack(spacing: 20) {
        ZStack {
            Circle()
                .fill(Color.blue.opacity(0.2))
                .frame(width: 64, height: 64)
            Image(systemName: "bolt.fill")
                .font(.system(size: 32))
                .foregroundColor(.blue)
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Charging Connected")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
            Text("\(tracker.currentBatteryLevel)% • \(tracker.powerAdapterWatts.map { "\($0)W" } ?? "Power Source")")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.6))
        }
        Spacer()
    }
}
```

- [ ] **Step 10: Remove unused `miniControlBtn` and `statDay` helpers**

Delete the `miniControlBtn(icon:label:isActive:tooltip:)` method and the `statDay(label:value:isHighlighted:)` method — they are replaced by `statChip`.

- [ ] **Step 11: Build and verify**

```bash
DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer" swift build 2>&1 | grep -E "error:|warning:"
```

Expected: zero errors. The `notchH` unused-variable warning may or may not remain (it will be fixed in Task 3).

- [ ] **Step 12: Commit**

```bash
git add Sources/DynamicIslandWindow.swift Sources/BatteryTracker.swift
git commit -m "feat: hover-to-expand Dynamic Island with power + thermals layout"
```

---

### Task 3: Fix remaining warnings and unused notchH variable

**Files:**
- Modify: `Sources/DynamicIslandWindow.swift`

**Interfaces:** None new.

- [ ] **Step 1: Fix notchH**

In `updateWindowFrame`, line ~433, change:
```swift
let notchH: CGFloat = 37.5
```
to:
```swift
let _: CGFloat = 37.5  // physical notch height — kept for reference
```
Or simply delete the line if nothing references it (it was never used).

- [ ] **Step 2: Build clean**

```bash
DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer" swift build 2>&1 | grep "error:"
```

Expected: zero errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/DynamicIslandWindow.swift
git commit -m "fix: remove unused notchH variable"
```

---

### Task 4: Manual smoke test

**Files:** None modified.

- [ ] **Step 1: Build release and install**

```bash
bash build.sh
```

- [ ] **Step 2: Launch and verify hover**

1. Open `/Applications/MacWake.app`
2. Move mouse slowly to the notch area at the top center of the screen
3. **Expected:** After ~150ms the panel smoothly expands to 580×220
4. Move mouse away from the panel
5. **Expected:** After ~300ms the panel smoothly collapses back to compact pill
6. Quickly hover and un-hover multiple times — panel should not flicker (debounce filters fast passes)

- [ ] **Step 3: Verify layout**

In expanded state:
- Left side: battery icon with color matching charge level, "Charging" or "On Battery" label, watt value or adapter name, screen-on time (when on battery)
- Right side: "Fanless" or RPM value, temperature bar chart with at least 1 bar, Health % and Cycles chips

- [ ] **Step 4: Verify charging banner**

Unplug and replug the MagSafe/USB-C — the charging banner (580×120) should appear for 5 seconds then collapse. Hovering during the banner should NOT trigger expand to full panel.

- [ ] **Step 5: Verify no crash on multiple hover cycles**

Hover in/out 20+ times rapidly. App should remain stable with no spinning beach ball.
