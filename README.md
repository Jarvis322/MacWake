# 🔋 MacWake

**MacWake** is an elegant menu bar and desktop widget application designed for macOS to track detailed battery health, usage analytics, and charging habits. Built with Swift and SwiftUI, it faithfully embraces modern macOS design guidelines (glassmorphism, vibrant effects).

<p align="center">
  <img src="Screenshots/menubar-popover.png" alt="MacWake menu bar panel" width="380">
</p>

---

## 🖥️ Dynamic Island & Menu Bar

A **Dynamic Island** lives in the notch: it stays
collapsed and blends with the hardware, expands on hover or click with a bouncy
spring, and gives haptic feedback. It surfaces live power, battery health, and
battery temperature, alongside quick toggles for the widget, session reset,
animations, and notifications.

<p align="center">
  <img src="Screenshots/dynamic-island.png" alt="MacWake Dynamic Island" width="760">
</p>

The **menu bar** shows real-time power draw at a glance (shown above), and
clicking it opens the full panel — Session, History, Hardware, and Settings.

<p align="center">
  <img src="Screenshots/menubar-item.png" alt="MacWake menu bar item" height="26">
</p>

---

## ✨ Features

*   **🔋 Charge Limit (full Apple Silicon M-series):**
    *   Cap charging at any level from 50% to 95% to reduce long-term battery wear.
    *   Picks the best method per chip: clean charge-inhibit (CHTE/CH0C) on M1/M2/M3, adapter control (CHIE) on M4 — via a small notarized background helper (one-time approval, no password prompts).
    *   **⛵ Sailing Mode:** let the battery drift down to a lower bound before topping back up, instead of micro-charging at the ceiling — fewer cycles, less heat.
    *   **🧪 Battery Calibration:** periodically charge to 100% to recalibrate the fuel gauge, with a "Calibrate Now" button.
*   **⚡️ Energy Mode:**
    *   Switch the macOS Energy Mode (Automatic / Low Power / High Power) right from the menu — High Power shown only on Macs that support it.
*   **🌀 Manual Fan Speed (experimental):**
    *   On Macs with fans, set a manual target RPM — automatically reverts to system control above 92°C as a safety failsafe.
*   **🎛️ Customizable Menu Bar:**
    *   Choose exactly what the menu-bar item shows — icon, battery %, power/time, estimated time remaining, and temperature — with a live preview.
*   **🏝️ Dynamic Island (Notch UI):**
    *   Panel that hugs the physical notch and blends with the hardware when collapsed.
    *   Hover or click to expand with a bouncy spring animation and haptic feedback.
    *   A **JARVIS-style arc-reactor HUD** with rotating tick rings and a glowing core that pulses with charging power.
    *   At-a-glance power, battery health, and temperature, plus quick toggles (widget, reset, animations, notifications).
*   **🌍 Localization:**
    *   Full English and Turkish UI, automatically following the macOS system language.
*   **📊 Detailed Session Tracking (Current Session):** 
    *   Tracks screen-on time and sleep duration.
    *   Seamless data integrity with restart/shutdown detection.
    *   Efficiency calculation showing average screen time per 1% battery drop.
*   **🖱️ Translucent Desktop Widget:**
    *   Floating widget that can be locked and positioned anywhere on the desktop.
    *   Apple-style circular battery level indicator.
    *   Real-time battery temperature and cycle count monitoring.
*   **🔌 Smart Power Adapter Analysis & Hybrid Algorithm:**
    *   **⚡️ Hybrid Power Draw:** Seamlessly combines total system power draw (`SystemPowerIn`) when plugged in and discharge rate (`InstantAmperage`) when on battery to accurately display real-time (dynamic) Watt consumption in the menu bar, without requiring root (`sudo`) privileges.
    *   Monitors the nominal wattage (e.g., 30W) and actual charging status of the connected adapter.
    *   Apple Genuine adapter verification (MFI Check).
    *   Identifies the port in use (MagSafe, USB-C, or Thunderbolt).
    *   **Slow Charging Alert** for low-efficiency charging scenarios.
    *   Adapter History logging to track the usage count of all past chargers.
*   **⏰ Fast Battery Drain Notifications:**
    *   Detects sudden battery drops (e.g., 5% or more) within the last 10 minutes while on battery and sends an immediate local notification.
*   **💫 iPhone-Style Charging Animation:**
    *   An elegant, fullscreen transition animation that appears in the center of the screen when the charging cable is plugged in, displaying the current percentage (can be toggled in settings).
*   **🛡️ Smart Battery Protection & Temperature Alerts:**
    *   Immediate visual warning card and local notification when battery temperature exceeds the 38°C threshold.
    *   Discharge warning to protect battery health if the device remains plugged in at 99%+ charge for more than 24 consecutive hours.
*   **📈 Battery Health Decay Log:**
    *   Automated historical log that records the date and cycle count every time the maximum battery capacity changes.
    *   Displays a stylish timeline of retroactive capacity degradation in the Hardware tab.
*   **🚀 Easy Access & Auto-Start:**
    *   Option to automatically Launch at Login.
    *   Advanced dynamic color palette compatible with dark/light modes.

---

## 🛠️ Installation

### Option 1 — Homebrew (Recommended)

```bash
brew tap Jarvis322/tap
brew install --cask macwake
```

### Option 2 — Direct Download

Download the latest `Wake-1.0.dmg` from [GitHub Releases](https://github.com/Jarvis322/MacWake/releases), open the DMG, and drag **MacWake.app** to your Applications folder.

### Requirements
*   **macOS 14.0 (Sonoma)** or later
*   Apple Silicon or Intel

### Manual Terminal Commands
If you wish to manage the app via the terminal:

*   **To Launch the App:**
    ```bash
    open /Applications/MacWake.app
    ```
*   **To Quit the App:**
    ```bash
    killall MacWake
    ```

---

## 📂 Project Structure

*   `Sources/MacWakeApp.swift`: Application lifecycle, menu bar integration, and single-instance management.
*   `Sources/BatteryTracker.swift`: Power state tracking (IOKit & IOPS), session data storage, and notification logic.
*   `Sources/MacWakeMenuView.swift`: Main UI components and timeline graphs revealed upon clicking the menu bar icon.
*   `Sources/WidgetWindow.swift`: Floating desktop widget window, drag logic, and circular indicator.
*   `Sources/ChargingAnimation.swift`: Fullscreen animation layer triggered when the charging cable is connected.
*   `Sources/LaunchAgentManager.swift`: Login item configuration using the macOS `SMAppService` API.

---

## ❤️ Support

MacWake is free and developed in my spare time. If it helps your battery, consider [sponsoring on GitHub](https://github.com/sponsors/Jarvis322) — it directly supports continued development.

---

## 🔒 Security & Permissions

The application does not require any administrator (root) privileges to monitor battery status and charging adapters; it relies entirely on standard macOS IOKit APIs. 
*   **Notifications:** To receive fast discharge alerts, it is recommended to grant notification permissions when the app first launches (this can be managed via the "Enable/Settings" button under the Menu).

---

## 📄 License
This project is licensed under **All Rights Reserved**. All intellectual property rights, including source code, designs, and compiled builds, are reserved by the author. Unauthorized copying, modification, or redistribution of the source is prohibited. The author retains the exclusive right to publish and distribute MacWake, including on the Mac App Store.
