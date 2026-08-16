import Foundation
import CaffCtlCore
import Darwin

func printUsage() {
    let usage = """
    CaffCtl — Native macOS sleep prevention controller

    USAGE:
      caffctl                      Activate indefinite wake session
      caffctl <duration>           Activate wake session for duration (e.g. 30m, 1h, 2h, 4h, 90s)
      caffctl -d, --duration <dur> Activate wake session for duration
      caffctl -w, --pid <PID>      Keep awake while PID is running
      caffctl unbind <PID>         Stop watching PID
      caffctl status               Show current wake status
      caffctl stop                 Stop wake session and allow system sleep
      caffctl -h, --help           Show this help message

    WRAPPER MODE:
      When invoked as 'caffeinate':
        caffeinate [flags] <cmd>    -> Runs command and keeps Mac awake until it finishes
        caffeinate -w <PID>         -> Binds to PID
        caffeinate -t <seconds>     -> Activates wake session for duration
        caffeinate &                -> Activates global wake session in background
    """
    print(usage)
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let mins = Int(ceil(seconds / 60.0))
    if mins >= 60 {
        let hrs = mins / 60
        let remainMins = mins % 60
        if remainMins == 0 {
            return "\(hrs)h"
        }
        return "\(hrs)h \(remainMins)m"
    }
    return "\(mins)m"
}

func printStatus(_ status: StatusPayload) {
    print("CaffCtl Status:")
    if status.isActive {
        print("  State: ACTIVE (Keeping Mac awake)")
    } else {
        print("  State: INACTIVE (System sleep allowed)")
    }

    if let global = status.global {
        if let remaining = global.remainingSeconds {
            print("  Global Session: Active (\(formatDuration(remaining)) remaining)")
        } else {
            print("  Global Session: Active (Indefinite)")
        }
    } else {
        print("  Global Session: None")
    }

    if status.processes.isEmpty {
        print("  Bound Processes: None")
    } else {
        print("  Bound Processes (\(status.processes.count)):")
        for proc in status.processes {
            let totalSec = max(0, Int(proc.elapsedSeconds))
            let timeStr: String
            if totalSec < 60 {
                timeStr = "\(totalSec)s"
            } else if totalSec < 3600 {
                timeStr = "\(totalSec / 60)m \(totalSec % 60)s"
            } else {
                timeStr = "\(totalSec / 3600)h \((totalSec % 3600) / 60)m"
            }
            print("    • \(proc.name) (PID: \(proc.pid)) — running for \(timeStr)")
        }
    }

    print("  Caffeinate Assertion: \(status.caffeinateRunning ? "Active" : "Inactive")")

    if let err = status.lastError {
        print("  Last Error: \(err)")
    }
}

func runCaffeinateWrapper(rawArgs: [String]) {
    var i = 0
    var watchPID: pid_t? = nil
    var timeoutDuration: TimeInterval? = nil
    var commandArgs: [String] = []

    while i < rawArgs.count {
        let arg = rawArgs[i]
        if arg == "-w" && i + 1 < rawArgs.count {
            watchPID = pid_t(rawArgs[i + 1])
            i += 2
        } else if arg.hasPrefix("-w") && arg.count > 2 {
            let pidStr = String(arg.dropFirst(2))
            watchPID = pid_t(pidStr)
            i += 1
        } else if arg == "-t" && i + 1 < rawArgs.count {
            timeoutDuration = TimeInterval(rawArgs[i + 1])
            i += 2
        } else if arg.hasPrefix("-t") && arg.count > 2 {
            let durStr = String(arg.dropFirst(2))
            timeoutDuration = TimeInterval(durStr)
            i += 1
        } else if ["-d", "-i", "-m", "-s", "-u"].contains(arg) {
            i += 1
        } else if arg.hasPrefix("-") && arg.count > 1 && arg.dropFirst().allSatisfy({ "dimsu".contains($0) }) {
            i += 1
        } else {
            commandArgs = Array(rawArgs[i...])
            break
        }
    }

    // 1. If running a utility command (e.g. caffeinate sleep 10 or caffeinate make):
    if !commandArgs.isEmpty {
        runUtilityCommandWithWakeLock(commandArgs: commandArgs)
        return
    }

    // 2. If watching an existing PID (e.g. caffeinate -w 12345):
    if let pid = watchPID, pid > 0 {
        runWatchPIDWakeLock(targetPID: pid)
        return
    }

    // 3. If timed wake lock (e.g. caffeinate -t 3600):
    if let dur = timeoutDuration, dur > 0 {
        runTimedWakeLock(seconds: dur)
        return
    }

    // 4. Indefinite wake lock (e.g. caffeinate or caffeinate &):
    runIndefiniteWakeLock()
}

func runIndefiniteWakeLock() {
    let client = IPCClient()
    if !client.isServerResponsive(timeout: 0.15) {
        launchAppIfNeeded(client: client)
    }

    let myPID = ProcessInfo.processInfo.processIdentifier
    _ = try? client.sendSync(request: .activateGlobal(duration: nil, clientPID: myPID), timeout: 2.0)

    signal(SIGINT) { _ in
        let c = IPCClient()
        _ = try? c.sendSync(request: .deactivateGlobal, timeout: 1.0)
        exit(0)
    }
    signal(SIGTERM) { _ in
        exit(0)
    }

    while true {
        pause()
    }
}

func runTimedWakeLock(seconds: TimeInterval) {
    let client = IPCClient()
    if !client.isServerResponsive(timeout: 0.15) {
        launchAppIfNeeded(client: client)
    }

    let myPID = ProcessInfo.processInfo.processIdentifier
    _ = try? client.sendSync(request: .activateGlobal(duration: seconds, clientPID: myPID), timeout: 2.0)

    signal(SIGINT) { _ in
        let c = IPCClient()
        _ = try? c.sendSync(request: .deactivateGlobal, timeout: 1.0)
        exit(0)
    }
    signal(SIGTERM) { _ in
        exit(0)
    }

    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 { break }
        usleep(useconds_t(min(remaining, 1.0) * 1_000_000))
    }

    _ = try? client.sendSync(request: .deactivateGlobal, timeout: 1.0)
    exit(0)
}

func runWatchPIDWakeLock(targetPID: pid_t) {
    guard ProcessBinding.processExists(pid: targetPID) else {
        fputs("caffeinate: PID \(targetPID) is not running\n", stderr)
        exit(1)
    }

    let client = IPCClient()
    if !client.isServerResponsive(timeout: 0.15) {
        launchAppIfNeeded(client: client)
    }

    _ = try? client.sendSync(request: .bindProcess(pid: targetPID), timeout: 2.0)

    signal(SIGINT) { _ in exit(130) }
    signal(SIGTERM) { _ in exit(143) }

    while ProcessBinding.processExists(pid: targetPID) {
        usleep(250_000)
    }

    exit(0)
}

func runUtilityCommandWithWakeLock(commandArgs: [String]) {
    let client = IPCClient()
    if !client.isServerResponsive(timeout: 0.15) {
        launchAppIfNeeded(client: client)
    }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = commandArgs
    proc.standardInput = FileHandle.standardInput
    proc.standardOutput = FileHandle.standardOutput
    proc.standardError = FileHandle.standardError

    do {
        try proc.run()
        let childPID = proc.processIdentifier
        _ = try? client.sendSync(request: .bindProcess(pid: childPID), timeout: 2.0)

        signal(SIGINT) { _ in }
        signal(SIGTERM) { _ in }

        proc.waitUntilExit()
        exit(proc.terminationStatus)
    } catch {
        fputs("caffeinate: Failed to execute '\(commandArgs[0])': \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

func runCLI() {
    let execName = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
    let rawArgs = Array(CommandLine.arguments.dropFirst())

    // 1. Caffeinate wrapper detection
    if execName == "caffeinate" {
        runCaffeinateWrapper(rawArgs: rawArgs)
        return
    }

    // 2. Caffeine CLI parsing
    if rawArgs.isEmpty {
        sendIPCRequest(.activateGlobal(duration: nil))
        return
    }

    let first = rawArgs[0]

    switch first {
    case "-h", "--help", "help":
        printUsage()
        exit(0)

    case "status", "--status":
        sendIPCRequest(.status)

    case "stop", "--stop":
        sendIPCRequest(.stop)

    case "unbind", "--unbind":
        guard rawArgs.count > 1, let pid = Int32(rawArgs[1]), pid > 0 else {
            fputs("Error: unbind requires a valid positive PID argument\n", stderr)
            exit(1)
        }
        sendIPCRequest(.unbindProcess(pid: pid))

    case "-w", "--pid", "-p":
        guard rawArgs.count > 1, let pid = Int32(rawArgs[1]), pid > 0 else {
            fputs("Error: --pid requires a valid positive PID argument\n", stderr)
            exit(1)
        }
        sendIPCRequest(.bindProcess(pid: pid))

    case "-d", "--duration", "-t", "--time":
        guard rawArgs.count > 1, let duration = DurationParser.parse(rawArgs[1]) else {
            fputs("Error: Invalid duration format. Example formats: 30m, 1h, 2h, 4h, 1800\n", stderr)
            exit(1)
        }
        sendIPCRequest(.activateGlobal(duration: duration))

    default:
        // Try parsing direct duration e.g. "caffeine 30m"
        if let duration = DurationParser.parse(first) {
            sendIPCRequest(.activateGlobal(duration: duration))
            return
        }
        // Try parsing direct PID e.g. "caffeine 12345" if it's all digits and process exists
        if let pid = Int32(first), pid > 0, rawArgs.count == 1 {
            sendIPCRequest(.bindProcess(pid: pid))
            return
        }

        fputs("Error: Unknown command or option '\(first)'. Run 'caffctl --help' for usage.\n", stderr)
        exit(1)
    }
}

func handleResponse(_ response: IPCResponse) -> Never {
    switch response {
    case .status(let statusPayload):
        printStatus(statusPayload)
        exit(0)
    case .ok(let msg):
        print(msg)
        exit(0)
    case .error(let msg):
        fputs("Error: \(msg)\n", stderr)
        exit(1)
    }
}

func launchAppIfNeeded(client: IPCClient) {
    // 1. Remove stale socket file if any
    unlink(client.socketPath)

    let rawPath = CommandLine.arguments[0]
    let baseDir = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().deletingLastPathComponent()

    let appLocations = [
        "/Applications/CaffCtl.app",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/CaffCtl.app").path,
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/CaffCtlApp").path,
        baseDir.appendingPathComponent("CaffCtl.app").path,
        baseDir.appendingPathComponent("CaffCtlApp").path
    ]

    var launched = false
    for appPath in appLocations where FileManager.default.fileExists(atPath: appPath) {
        if appPath.hasSuffix(".app") {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = [appPath]
            try? proc.run()
        } else {
            var pid: pid_t = 0
            var args: [UnsafeMutablePointer<CChar>?] = [strdup(appPath), nil]
            posix_spawn(&pid, appPath, nil, nil, &args, nil)
        }
        launched = true
        break
    }

    if !launched {
        let openProc = Process()
        openProc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProc.arguments = ["-a", "CaffCtl"]
        openProc.standardError = Pipe()
        try? openProc.run()
        openProc.waitUntilExit()
    }

    let deadline = Date().addingTimeInterval(3.0)
    while Date() < deadline {
        if client.isServerResponsive(timeout: 0.15) {
            return
        }
        usleep(50_000)
    }
}

func sendIPCRequest(_ request: IPCRequest) {
    let client = IPCClient()

    do {
        let response = try client.sendSync(request: request, timeout: 1.5)
        handleResponse(response)
    } catch IPCClientError.serverNotRunning {
        // App is not running: automatically launch it and retry!
        launchAppIfNeeded(client: client)
        do {
            let response = try client.sendSync(request: request, timeout: 3.0)
            handleResponse(response)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

runCLI()
