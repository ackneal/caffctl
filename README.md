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
- 🛠 **100% Drop-in `caffeinate` Wrapper**  
  Use `caffeinate` exactly like you always have (`caffeinate make`, `caffeinate sleep 3600 &`). CaffCtl automatically captures the process, displays it in your Menu Bar, and releases sleep lock the moment the job finishes.
- 🔍 **Real-Time Process & Session Monitor**  
  View all active processes keeping your Mac awake with elapsed running times. Hover to inspect full command lines, click the process icon to copy its PID, or click **Release** to stop watching anytime.
- 🚀 **Auto-Launching Terminal Integration**  
  Running `caffeinate` in terminal automatically wakes the Menu Bar App in the background within 0.2s with zero setup.
- 🛡 **Safe, Reliable & Energy Efficient**  
  No orphaned processes, automatic restart recovery, zero battery drain when inactive, and complete cleanup on quit.

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

Use `caffeinate` exactly like native macOS `caffeinate` with 100% argument and behavior compatibility:

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

> 💡 **Bonus**: Any command run with `caffeinate` will immediately show up in your Menu Bar Sessions list with its elapsed time and process icon!

---

### 2. Menu Bar GUI Interactions

| Action | How to use |
| :--- | :--- |
| **Toggle Indefinite Awake** | Click the Menu Bar coffee icon ➜ Flip the **GLOBAL** switch. |
| **Choose Duration Preset** | Click the Duration row ➜ Pick `30 min`, `1 hr`, `2 hr`, `4 hr`, or enter `Custom...`. |
| **Inspect Active Sessions** | Click `Sessions [ N ]` to view all watching processes. |
| **Copy Process PID** | Click any process icon in the Sessions list to copy its PID (with green `✓` feedback). |
| **View Full Command Line** | Hover your mouse over any session row to see the exact terminal command. |
| **Release a Process Lock** | Click the **Release** button next to any running session. |
| **Quit CaffCtl** | Click **Quit** (`⌘Q`) at the bottom right. |

---

## 📋 Command Cheat Sheet

| Command | Action |
| :--- | :--- |
| `caffeinate &` | Activate indefinite wake session in background (shows in Sessions) |
| `caffeinate -t <seconds>` | Activate wake session for duration in seconds |
| `caffeinate -w <PID>` | Keep awake while specific process PID is running |
| `caffeinate <command>` | Run command with automatic sleep lock & session monitoring |

---

## 🛠 Requirements

- **System**: macOS 14.0 (Sonoma) or later (Apple Silicon & Intel supported)
- **Building from Source**: Swift 6.0+ / Xcode 16.0+ (Command Line Tools)

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
