import Foundation
import os

public protocol CaffeinateProcessProtocol: AnyObject, Sendable {
    var isRunning: Bool { get }
    var failureTimestamps: [Date] { get }
    var onUnexpectedExit: (@MainActor @Sendable () -> Void)? { get set }
    func start() throws
    func stop()
}

public enum CaffeinateError: LocalizedError, Sendable, Equatable {
    case alreadyRunning
    case launchFailed(String)
    case restartLimitExceeded
    case notFound

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Caffeinate process is already running."
        case .launchFailed(let reason):
            return "Failed to launch caffeinate: \(reason)"
        case .restartLimitExceeded:
            return "Caffeinate failed repeatedly (max 3 failures within 10s exceeded)."
        case .notFound:
            return "caffeinate executable not found at /usr/bin/caffeinate."
        }
    }
}

public final class CaffeinateProcess: CaffeinateProcessProtocol, @unchecked Sendable {
    private static let caffeinatePath = "/usr/bin/caffeinate"
    private static let maxFailures = 3
    private static let failureWindowSeconds: TimeInterval = 10.0

    private let lock = NSLock()
    private var process: Process?
    private var isExpectedToRun = false
    private var _failureTimestamps: [Date] = []
    private let targetPID: pid_t

    public var onUnexpectedExit: (@MainActor @Sendable () -> Void)?

    public init(targetPID: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.targetPID = targetPID
    }

    deinit {
        stop()
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    public var failureTimestamps: [Date] {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        return _failureTimestamps.filter { now.timeIntervalSince($0) <= Self.failureWindowSeconds }
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }

        if let proc = process, proc.isRunning {
            return
        }

        let now = Date()
        _failureTimestamps = _failureTimestamps.filter { now.timeIntervalSince($0) <= Self.failureWindowSeconds }
        if _failureTimestamps.count >= Self.maxFailures {
            Log.wake.error("Caffeinate restart limit exceeded (\(Self.maxFailures) failures in \(Self.failureWindowSeconds)s)")
            throw CaffeinateError.restartLimitExceeded
        }

        guard FileManager.default.isExecutableFile(atPath: Self.caffeinatePath) else {
            throw CaffeinateError.notFound
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.caffeinatePath)
        proc.arguments = ["-i", "-w", String(targetPID)]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] terminatedProc in
            guard let self = self else { return }
            self.lock.lock()
            let wasUnexpected = self.isExpectedToRun
            self.process = nil
            if wasUnexpected {
                let timestamp = Date()
                self._failureTimestamps.append(timestamp)
                let recentFailures = self._failureTimestamps.filter { timestamp.timeIntervalSince($0) <= Self.failureWindowSeconds }.count
                Log.wake.warning("caffeinate process terminated unexpectedly (exit code: \(terminatedProc.terminationStatus), recent failures: \(recentFailures))")
            }
            self.lock.unlock()

            if wasUnexpected {
                Task { @MainActor [weak self] in
                    self?.onUnexpectedExit?()
                }
            }
        }

        do {
            try proc.run()
            self.process = proc
            self.isExpectedToRun = true
            Log.wake.info("caffeinate process started with PID \(proc.processIdentifier) watching target PID \(self.targetPID)")
        } catch {
            self.isExpectedToRun = false
            self.process = nil
            Log.wake.error("Failed to run caffeinate: \(error.localizedDescription)")
            throw CaffeinateError.launchFailed(error.localizedDescription)
        }
    }

    public func stop() {
        lock.lock()
        isExpectedToRun = false
        if let proc = process, proc.isRunning {
            proc.terminationHandler = nil
            proc.terminate()
            Log.wake.info("caffeinate process terminated")
        }
        process = nil
        lock.unlock()
    }
}
