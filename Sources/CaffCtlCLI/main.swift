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
    let classification = classifyCaffeinate(arguments: rawArgs)
    spawnTrackingHelper(
        pid: ProcessInfo.processInfo.processIdentifier,
        asGlobal: classification.isGlobal,
        duration: classification.duration
    )

    let executable = "/usr/bin/caffeinate"
    var arguments = ([executable] + rawArgs).map { strdup($0) }
    arguments.append(nil)
    defer {
        for argument in arguments where argument != nil {
            free(argument)
        }
    }

    execv(executable, &arguments)
    perror("caffeinate: failed to execute /usr/bin/caffeinate")
    exit(127)
}

func classifyCaffeinate(arguments: [String]) -> (isGlobal: Bool, duration: TimeInterval?) {
    var index = 0
    var duration: TimeInterval?

    while index < arguments.count {
        let argument = arguments[index]
        if argument == "-w" || argument.hasPrefix("-w") && argument.count > 2 {
            return (false, duration)
        }
        if argument == "-t", index + 1 < arguments.count {
            duration = TimeInterval(arguments[index + 1])
            index += 2
            continue
        }
        if argument.hasPrefix("-t"), argument.count > 2 {
            duration = TimeInterval(argument.dropFirst(2))
            index += 1
            continue
        }
        if argument.hasPrefix("-"), argument.dropFirst().allSatisfy({ "dimsu".contains($0) }) {
            index += 1
            continue
        }
        return (false, duration)
    }

    return (true, duration)
}

func spawnTrackingHelper(pid: pid_t, asGlobal: Bool, duration: TimeInterval?) {
    let mode = asGlobal ? "global" : "session"
    let durationArgument = duration.map { String($0) } ?? "none"
    let result = spawnCaffCtl(arguments: ["__spawn-tracker", mode, String(pid), durationArgument])
    guard result.error == 0 else {
        fputs("caffeinate: CaffCtl tracking helper unavailable (error \(result.error))\n", stderr)
        return
    }

    waitpid(result.pid, nil, 0)
}

func spawnCaffCtl(arguments: [String]) -> (pid: pid_t, error: Int32) {
    guard let executableURL = Bundle.main.executableURL else {
        return (0, ENOENT)
    }
    let executable = executableURL.resolvingSymlinksInPath().path
    let argumentStrings = [executable] + arguments
    var cArguments: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { strdup($0) }
    cArguments.append(nil)
    defer {
        for argument in cArguments where argument != nil {
            free(argument)
        }
    }

    var pid: pid_t = 0
    let error = posix_spawn(&pid, executable, nil, nil, &cArguments, environ)
    return (pid, error)
}

func trackCaffeinate(pid: pid_t, asGlobal: Bool, duration: TimeInterval?) {
    let client = IPCClient()
    if !client.isServerResponsive(timeout: 0.15) {
        launchAppIfNeeded(client: client)
    }

    do {
        let request: IPCRequest = asGlobal
            ? .trackGlobal(pid: pid, duration: duration)
            : .trackProcess(pid: pid)
        let response = try client.sendSync(request: request, timeout: 2.0)
        if case .error(let message) = response {
            fputs("caffeinate: CaffCtl tracking unavailable: \(message)\n", stderr)
        }
    } catch {
        fputs("caffeinate: CaffCtl tracking unavailable: \(error.localizedDescription)\n", stderr)
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

    if first == "__spawn-tracker" {
        guard rawArgs.count == 4 else { exit(1) }
        let result = spawnCaffCtl(arguments: ["__track-caffeinate"] + Array(rawArgs.dropFirst()))
        exit(result.error == 0 ? 0 : 1)
    }

    if first == "__track-caffeinate" {
        guard rawArgs.count == 4,
              let pid = pid_t(rawArgs[2]), pid > 0 else {
            exit(1)
        }
        let duration = rawArgs[3] == "none" ? nil : TimeInterval(rawArgs[3])
        trackCaffeinate(pid: pid, asGlobal: rawArgs[1] == "global", duration: duration)
        exit(0)
    }

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
