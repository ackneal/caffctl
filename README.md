# ☕ CaffCtl

> **The Modern, Native macOS Sleep Prevention Tool & `caffeinate` Manager**  
> *Keep your Mac awake during long tasks, builds, and downloads — seamlessly integrated into both your Menu Bar and Terminal.*

[![macOS](https://img.shields.io/badge/macOS-14.0%2B-black?style=flat-square&logo=apple)](https://apple.com)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange?style=flat-square&logo=swift)](https://swift.org)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)

---

## 🌟 Why CaffCtl?

If you are a developer, designer, or power user running long-running jobs (e.g. `make`, `npm build`, `cargo build`, machine learning models, database migrations, or large file transfers), macOS sleep mode can unexpectedly pause your progress.

**CaffCtl** bridges the gap between Apple's native command-line `/usr/bin/caffeinate` and a beautiful, minimalist Menu Bar App. It gives you full visual oversight and instant terminal control without messy background processes or battery drain.

---

## ✨ Features

- ☕ **Native & Minimalist Menu Bar UI**  
  A clean, monochrome SF Symbol coffee cup indicator that seamlessly blends with your macOS desktop. Click to see remaining time, active sessions, and quick toggles.
- ⚡ **Zero-Configuration Timers**  
  Quickly set sleep prevention for **30 minutes**, **1 hour**, **2 hours**, **4 hours**, or custom minutes — or keep awake indefinitely.
- 🛠 **Native `caffeinate` Wrapper**
  Use `caffeinate` exactly as you normally would (`caffeinate make`, `caffeinate -d -i -t 3600`). Every argument is passed unchanged to `/usr/bin/caffeinate`; CaffCtl only adds Menu Bar tracking.
- 🔍 **Real-Time Process & Session Monitor**  
  View all active processes keeping your Mac awake with elapsed running times. Hover to inspect full command lines, click the process icon to copy its PID, or click **Release** to stop watching anytime.
- 🚀 **Auto-Launching Terminal Integration**  
  Running `caffeinate` in Terminal automatically launches the Menu Bar App in the background for tracking.
- 🛡 **Safe, Reliable & Energy Efficient**  
  Native caffeinate remains responsible for the sleep assertion and releases it when the process exits. If the App or tracking IPC is unavailable, sleep prevention still works; only Menu Bar tracking is skipped.

---

## 📦 Installation

Clone the repository and run the automated installer:

```bash
git clone https://github.com/ackneal/caffctl.git
cd caffctl
./scripts/install.sh
```

> **What this script does:**  
> 1. Compiles the high-performance release build with Swift 6.  
> 2. Installs `CaffCtl.app` into `/Applications/`.  
> 3. Links `caffeinate` to `~/.local/bin/` for seamless terminal use and instant Tab autocomplete.

---

## 💻 How to Use

### 1. Transparent `caffeinate` Wrapper Mode

Wrapper arguments are passed unchanged to native macOS `/usr/bin/caffeinate`:

```bash
# Wrap long-running compilation or scripts in foreground
caffeinate make -j8

# Keep Mac awake in background with standard & job
caffeinate sleep 3600 &
caffeinate &

# Watch an existing process by PID
caffeinate -w 84210

# Set timed wake lock
caffeinate -t 3600
```

> Caffeinate without a utility or `-w` target appears as **Global**. `caffeinate <command>` and `caffeinate -w <PID>` appear under **Sessions**. Tracking does not control native caffeinate behavior.

---

### 2. Menu Bar GUI Interactions

| Action | How to use |
| :--- | :--- |
| **Toggle Indefinite Awake** | Click the Menu Bar coffee icon ➜ Flip the **GLOBAL** switch. |
| **Choose Duration Preset** | Click the Duration row ➜ Pick `30 min`, `1 hr`, `2 hr`, `4 hr`, or enter `Custom...`. |
| **Inspect Active Sessions** | Click `Sessions [ N ]` to view all watching processes. |
| **Copy Process PID** | Click any process icon in the Sessions list to copy its PID (with green `✓` feedback). |
| **View Full Command Line** | Hover your mouse over any session row to see the exact terminal command. |
| **Stop Tracking a Session** | Click **Release** next to a session. This removes it from CaffCtl without terminating the process or its native assertion. |
| **Quit CaffCtl** | Click **Quit** (`⌘Q`) at the bottom right. |

---

## 📋 Command Cheat Sheet

| Command | Action |
| :--- | :--- |
| `caffeinate &` | Run an indefinite native wake assertion in the background (shows as Global) |
| `caffeinate -t <seconds>` | Run a timed native wake assertion (shows as Global) |
| `caffeinate -w <PID>` | Keep awake while a PID is running (shows in Sessions) |
| `caffeinate <command>` | Run a command with a native sleep assertion and Session monitoring |

---

## 🛠 Requirements

- **System**: macOS 14.0 (Sonoma) or later (Apple Silicon & Intel supported)
- **Building from Source**: Swift 6.0+ / Xcode 16.0+ (Command Line Tools)

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
