# Dynamic Island — NotchNook-Style Redesign

**Date:** 2026-06-18  
**Status:** Approved

---

## Goal

Replace the current click-to-expand Dynamic Island with a hover-activated panel that matches NotchNook's UX pattern, while keeping MacWake's battery/power focus.

---

## Hover Behavior

- **Open trigger:** Mouse enters the compact pill area → 150ms debounce → animate to `.expanded`
- **Close trigger:** Mouse exits the expanded panel → 300ms debounce → animate to `.compact`
- **Debounce rationale:** 150ms filters accidental hover-overs; 300ms gives tolerance for moving within the panel
- **Charging / alert states:** Auto-dismiss after 5s as before; hover while banner is shown does NOT override to expanded (banner takes priority)
- **Implementation:** `NSTrackingArea` on the `NSPanel` content view — updates whenever the window frame changes (state transitions). No global mouse polling.

---

## Layout

### Compact (200 × 36)
- Battery icon + percentage, centered in pill
- Mouse hover zone covers the full pill

### Expanded (580 × 220)
Two-column layout separated by a subtle divider:

**Left Widget — Power**
- Large battery icon (gradient, reflects charge level)
- Charging/On Battery label (English)
- `%XX Capacity` subtitle
- Dynamic watt reading (e.g. `47.3W`) or adapter name
- Screen-on session time (when on battery)

**Right Widget — Thermals**
- Fan RPM (large number); if no fans: "Fanless" label
- Mini bar chart of last 5 temperature samples (dot + bar style)
- Health % and cycle count as stat chips

### Charging Banner (580 × 120) — unchanged, 5s auto-dismiss
### Alert Banner (580 × 120) — unchanged, 5s auto-dismiss

---

## Animation

- Spring: `response: 0.35, dampingFraction: 0.8` for all state transitions
- Both `width` and `height` animate via `NSPanel.setFrame(_:display:animate:)` + SwiftUI content transition
- Content uses `.transition(.move(edge: .top).combined(with: .opacity))`

---

## Architecture Changes

### `DynamicIslandManager`
- Remove `setupClickMonitor` (outside-click-to-collapse logic)
- Add `setupHoverTracking()` — installs `NSTrackingArea` on panel's `contentView`
- Add `scheduleExpand()` / `scheduleCollapse()` with debounce timers
- Hover tracking area is recreated on every `updateWindowFrame` call

### `DynamicIslandPanelView`
- Remove `.onTapGesture` expand/collapse toggle
- Add `NSViewRepresentable` wrapper (`HoverTrackingView`) that forwards `mouseEntered`/`mouseExited` to `DynamicIslandManager`
- Left widget: show `dynamicWatts` if available, else `powerAdapterWatts`, else adapter name
- Right widget: fan RPM from `currentFanSpeed` / `hasFans`, temperature mini-chart from `fanSpeedHistory` (repurpose or add `temperatureHistory`)

### `DynamicIslandState`
- No new states needed; existing `.compact / .charging / .alert / .expanded` covers everything

---

## Strings (English)

All user-visible strings in `DynamicIslandWindow.swift` will be in English:
- `"Charging"` / `"On Battery"`
- `"Charging Connected"`
- `"Fanless"` (for Apple Silicon with no fans)

---

## Out of Scope

- Music/media widget (not relevant to MacWake)
- Draggable/repositionable panel
- Settings for hover delay customization
