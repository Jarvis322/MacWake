# MacWake — Mac App Store Submission Guide

This is the checklist to ship MacWake on the Mac App Store. The codebase is now
sandbox-compatible (see "What changed" at the bottom). The remaining work is
account setup, signing, metadata, and assets — none of it is code.

---

## 1. Prerequisites

- [ ] **Apple Developer Program** membership ($99/yr) — required to submit.
- [ ] Sign in to **App Store Connect** (https://appstoreconnect.apple.com).
- [ ] In Xcode → Settings → Accounts, add the Apple ID for the team
      (`MN42QBM28Y`). Let Xcode manage **Apple Distribution** certificates and
      the **Mac App Store provisioning profile** automatically.

> The Mac currently has only an "Apple Development" certificate. App Store
> distribution needs an **Apple Distribution** certificate + a Mac App Store
> provisioning profile. Xcode's "Automatically manage signing" creates both.

---

## 2. Bundle identifier & app name — DECIDED

- **Bundle ID:** `com.jarvisit.macwake` (set in `project.yml` and `build.sh`).
- **App Store listing name:** `Wake — Battery Health` (avoids the "Mac" prefix
  that Apple often rejects). The app's user-facing display name is **Wake**
  (`CFBundleDisplayName`); the bundle/binary stays `MacWake` internally.
- [ ] Register the App ID `com.jarvisit.macwake` once in App Store Connect →
      Identifiers (or let Xcode create it on first archive).

---

## 3. Build, sign & upload (Xcode project is generated)

The Xcode app target is generated from **`project.yml`** with xcodegen — it sets
the bundle ID, App Sandbox entitlement, icon asset catalog, `LSUIElement`,
versions, and team. A hand-rolled SwiftPM bundle cannot embed a provisioning
profile or produce a signed `.pkg`, which the store requires; this target can.

1. [ ] Regenerate (only needed after editing `project.yml`):
       ```bash
       xcodegen generate
       open MacWake.xcodeproj
       ```
2. [ ] First time only: point the CLI at the full Xcode if you'll use it —
       `sudo xcode-select -s /Applications/Xcode.app`.
3. [ ] In Xcode: target **MacWake** → Signing & Capabilities → "Automatically
       manage signing", Team = `MN42QBM28Y`. Xcode creates the **Apple
       Distribution** cert + Mac App Store provisioning profile on first archive.
4. [ ] Product → **Archive** → Organizer → **Distribute App** →
       **App Store Connect** → Upload.

`build.sh` stays useful for **local testing only**: it ad-hoc signs with the
sandbox entitlement so the app behaves exactly as it will in the store
(container paths, restricted IOKit). It is *not* a submission path.

---

## 4. Info.plist / entitlements — already done

- [x] `MacWake.entitlements`: App Sandbox only (prohibited temporary-exception
      entitlement removed).
- [x] `Info.plist`: `LSUIElement`, `LSApplicationCategoryType` = utilities,
      `LSMinimumSystemVersion` = 14.0, copyright, `ITSAppUsesNonExemptEncryption
      = false` (skips the export-compliance prompt on every upload).
- [ ] Bump `CFBundleShortVersionString` / `CFBundleVersion` per release.

---

## 5. App Store Connect metadata

- [ ] Category: **Utilities**.
- [ ] Description, subtitle, keywords, promotional text.
- [ ] **Support URL** and **Marketing URL** (a simple page is enough).
- [ ] **Privacy Policy URL** (required). MacWake collects nothing — a one-page
      "no data collected, all processing is on-device" policy suffices.
- [ ] **App Privacy** questionnaire → **Data Not Collected** (no analytics, no
      account, no tracking).
- [ ] **Review notes (important):** MacWake is a menu-bar-only app
      (`LSUIElement`) with **no Dock icon and no main window**. Tell the
      reviewer explicitly: *"After launch, the app appears in the macOS menu
      bar (top-right). Click the battery icon to open the panel."* Apps with no
      visible window are frequently rejected as "we couldn't find the UI" — this
      note prevents that.

---

## 6. Screenshots & assets

- [ ] App Store macOS screenshots must be **1280×800, 1440×900, 2560×1600, or
      2880×1800**. The files in `Screenshots/` are cropped UI panels for the
      README, not full-window store shots — capture proper ones.
- [x] App icon: `Assets.xcassets/AppIcon.appiconset` generated (all 10 macOS
      sizes from `app_icon_source.png`) and compiled into the app bundle.

---

## 7. Pre-submit smoke test

- [ ] `./build.sh` then launch `/Applications/MacWake.app`; confirm the menu bar
      item shows live watts, the panel opens, Hardware tab shows health / cycles
      / battery temp, the widget and Dynamic Island work, and "Launch at Login"
      toggles. Verify no sandbox denials:
      `log stream --predicate 'eventMessage CONTAINS "MacWake"' --level debug`
      and watch for `deny` while using the app on battery and while charging.

---

## What changed for the App Store (code)

The sandbox cannot reach the SMC, the private thermal interface, or other
processes' preferences, and the temporary-exception entitlement is banned on the
store. These features were therefore **removed**:

- Fan speed + 1h fan history (`SMCHelper.swift`, deleted)
- SoC/CPU · SSD · GPU temperatures (`ThermalSensors.swift`, private
  `IOHIDEventSystemClient` API, deleted)
- Optimized-charging-limit read from `powerd`/`batteryui` prefs
- Legacy `launchctl` cleanup (`SMAppService` already handles login items)

Everything else is sandbox-safe and intact: menu-bar live watts, battery
temperature, cycle count, health, Battery Health Decay log, session tracking,
adapter analysis/history, the desktop widget, the Dynamic Island, fast-drain &
temperature notifications, and launch-at-login.
