# CaffCtl — macOS Caffeinate Menu Bar App

**Keep your Mac awake, prevent macOS sleep, and manage native `caffeinate` sessions from the menu bar.** CaffCtl is a lightweight Swift app and command-line wrapper for `/usr/bin/caffeinate`.

[![macOS 14+](https://img.shields.io/badge/macOS-14.0%2B-black?style=flat-square&logo=apple)](https://www.apple.com/macos/)
[![Swift 6](https://img.shields.io/badge/Swift-6.0-orange?style=flat-square&logo=swift)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)

## Why CaffCtl?

macOS includes the powerful `caffeinate` command, but native assertions are difficult to see and manage after they start. CaffCtl adds a menu bar interface without replacing native caffeinate behavior.

- **Prevent Mac sleep.** Keep macOS awake indefinitely, for a fixed duration, while a command runs, or while a PID exists.
- **Use native caffeinate.** Wrapper arguments pass unchanged to `/usr/bin/caffeinate`, including `-d`, `-i`, `-m`, `-s`, `-u`, `-t`, and `-w`.
- **See active assertions.** View Global wake assertions and command/PID Sessions from the macOS menu bar.
- **Release assertions safely.** Stop a tracked caffeinate process without directly terminating its wrapped command or `-w` target.
- **Keep working if tracking fails.** The native caffeinate assertion still runs if the CaffCtl app or IPC tracking is unavailable.
- **Stay lightweight.** Native Swift, no third-party dependencies, and no background UI refresh while the popover is closed.

## Quick Start

### 1. Install CaffCtl

```bash
git clone https://github.com/ackneal/caffctl.git
cd caffctl
./scripts/install.sh
```

The installer:

1. Builds CaffCtl in release mode.
2. Installs `CaffCtl.app` in `/Applications`.
3. Links `~/.local/bin/caffeinate` to the bundled wrapper.

The app does not create or change command-line symlinks at runtime. Wrapper installation is handled only by `scripts/install.sh`.

### 2. Confirm the wrapper is active

```bash
which caffeinate
```

Expected path:

```text
/Users/your-name/.local/bin/caffeinate
```

If another path appears, add `~/.local/bin` before `/usr/bin` in your shell `PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Add that line to `~/.zshrc` to keep it after restarting Terminal.

### 3. Keep your Mac awake

```bash
# Keep the Mac awake until you stop caffeinate
caffeinate &

# Prevent idle sleep for one hour
caffeinate -i -t 3600

# Keep the display and Mac awake for five minutes
caffeinate -d -i -t 300

# Keep the Mac awake while a build runs
caffeinate make -j8

# Keep the Mac awake while an existing PID is alive
caffeinate -w 84210
```

Running the wrapper automatically launches CaffCtl for menu bar tracking. Native caffeinate starts independently, so sleep prevention does not depend on the app launching successfully.

## Global vs Sessions

CaffCtl groups native caffeinate assertions by how they are used:

| Type | Examples | Menu bar behavior |
| :--- | :--- | :--- |
| **Global** | `caffeinate &`, `caffeinate -i -t 3600` | Shows one indefinite or timed Global assertion. Starting another Global replaces the previous tracked Global. |
| **Session** | `caffeinate make`, `caffeinate -w 84210` | Shows each tracked native caffeinate PID under Sessions with elapsed time and process metadata. |

## Process Ownership and Safe Release

CaffCtl owns the lifecycle of native caffeinate processes registered through its wrapper. It does not own the command or PID that caffeinate watches.

```text
caffeinate make

native caffeinate PID 100  → CaffCtl may terminate PID 100
make PID 200               → CaffCtl never signals PID 200
```

```text
caffeinate -w 300

native caffeinate PID 100  → CaffCtl may terminate PID 100
watched target PID 300     → CaffCtl never signals PID 300
```

Clicking **Release**, choosing **Stop**, or quitting CaffCtl removes the tracked sleep assertion by terminating the native caffeinate PID. A wrapped command or watched target continues running.

## Menu Bar Controls

| Control | Action |
| :--- | :--- |
| **Global switch** | Start or stop an indefinite CaffCtl-managed wake assertion. |
| **Set Duration** | Keep the Mac awake for 30 minutes, 1 hour, 2 hours, 4 hours, or custom minutes. |
| **Global timer** | Show elapsed time or a live remaining-time countdown while the popover is open. |
| **Other Sessions** | Inspect command and PID-based caffeinate sessions. |
| **Process icon** | Copy the tracked PID. |
| **Session row** | Hover to view the current command line. |
| **Release** | Stop the native caffeinate assertion without directly stopping its command or watched PID. |
| **Quit** | Stop tracked assertions and close CaffCtl. |

## Native Caffeinate Compatibility

The wrapper replaces its own process with native caffeinate:

```text
CaffCtl wrapper → execv("/usr/bin/caffeinate", original arguments)
```

This preserves the PID and delegates assertion semantics to macOS. CaffCtl tracks that PID and resolves process metadata after `execv`, so the menu bar reflects native caffeinate rather than the temporary wrapper.

Common native flags:

| Flag | Native macOS behavior |
| :--- | :--- |
| `-d` | Prevent display sleep. |
| `-i` | Prevent idle system sleep. |
| `-m` | Prevent idle disk sleep. |
| `-s` | Prevent system sleep while on AC power. |
| `-u` | Declare user activity. |
| `-t <seconds>` | Release the assertion after a timeout. |
| `-w <PID>` | Release the assertion when the PID exits. |

See the macOS manual for complete native behavior:

```bash
man caffeinate
```

## Command Examples

| Command | Result |
| :--- | :--- |
| `caffeinate &` | Indefinite Global assertion in the background. |
| `caffeinate -i -t 1800` | Prevent idle sleep for 30 minutes. |
| `caffeinate -d -i -t 300` | Keep the display and system awake for five minutes. |
| `caffeinate make` | Prevent sleep while `make` runs and show it as a Session. |
| `caffeinate npm run build` | Prevent sleep while an npm build runs. |
| `caffeinate -w 84210` | Prevent sleep until PID 84210 exits. |

## Build and Test

Requirements:

- **Operating system:** macOS 14 Sonoma or later
- **Toolchain:** Swift 6 or Xcode 16 Command Line Tools
- **Dependencies:** none

Build the project:

```bash
swift build
```

Run the Swift package tests:

```bash
swift test
```

Run the standalone invariant test suite:

```bash
swift run CaffCtlTestsRunner
```

## Troubleshooting

### `which caffeinate` still shows `/usr/bin/caffeinate`

Ensure `~/.local/bin` comes before `/usr/bin`:

```bash
export PATH="$HOME/.local/bin:$PATH"
rehash
```

Open a new Terminal window and run `which caffeinate` again.

### CaffCtl does not show a session

The native assertion still works when tracking fails. Confirm the app is installed:

```bash
open -a CaffCtl
```

Then start a new caffeinate command.

### Check active macOS sleep assertions

```bash
pmset -g assertions | grep -A20 -i caffeinate
```

### Stop a background caffeinate command

Use the shell job or PID that started it:

```bash
jobs -l
kill <caffeinate-pid>
```

## License

CaffCtl is available under the [MIT License](LICENSE).
