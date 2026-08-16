import Foundation
import AppKit
import Darwin
import os

public protocol ProcessBindingProtocol: AnyObject, Sendable {
    var pid: pid_t { get }
    var processName: String { get }
    var commandLine: String { get }
    var fullPath: String { get }
    var appIcon: NSImage? { get }
    var startDate: Date { get }
    var elapsedSeconds: TimeInterval { get }
    var onExit: (@MainActor @Sendable (pid_t) -> Void)? { get set }
    func cancel()
}

public enum ProcessBindingError: LocalizedError, Sendable, Equatable {
    case invalidPID(pid_t)
    case processNotFound(pid_t)
    case alreadyBound(pid_t)

    public var errorDescription: String? {
        switch self {
        case .invalidPID(let pid):
            return "Invalid PID: \(pid). PID must be greater than 0."
        case .processNotFound(let pid):
            return "Process with PID \(pid) was not found."
        case .alreadyBound(let pid):
            return "Process with PID \(pid) is already bound."
        }
    }
}

public final class ProcessBinding: ProcessBindingProtocol, @unchecked Sendable {
    public let pid: pid_t
    public let processName: String
    public let commandLine: String
    public let fullPath: String
    public let startDate: Date
    public let appIcon: NSImage?
    private var source: (any DispatchSourceProcess)?
    private let lock = NSLock()

    public var elapsedSeconds: TimeInterval {
        Date().timeIntervalSince(startDate)
    }

    public var onExit: (@MainActor @Sendable (pid_t) -> Void)?

    public static func processExists(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    public static func resolveProcessPath(pid: pid_t) -> String {
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        if len > 0 {
            return pathBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }
        return ""
    }

    public static func resolveCommandLine(pid: pid_t) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0

        if sysctl(&mib, 3, nil, &size, nil, 0) != 0 || size <= 0 {
            return resolveProcessName(pid: pid)
        }

        var buffer = [CChar](repeating: 0, count: size)
        if sysctl(&mib, 3, &buffer, &size, nil, 0) != 0 {
            return resolveProcessName(pid: pid)
        }

        var argc: Int32 = 0
        memcpy(&argc, buffer, MemoryLayout<Int32>.size)

        var offset = MemoryLayout<Int32>.size

        // Skip the executable path
        while offset < size && buffer[offset] != 0 {
            offset += 1
        }
        // Skip trailing null bytes
        while offset < size && buffer[offset] == 0 {
            offset += 1
        }

        // Read arguments
        var args: [String] = []
        var argCount = 0
        while offset < size && argCount < argc {
            let start = offset
            while offset < size && buffer[offset] != 0 {
                offset += 1
            }
            if offset > start {
                let argBytes = Array(buffer[start..<offset])
                if let str = String(bytes: argBytes.map { UInt8(bitPattern: $0) }, encoding: .utf8) {
                    args.append(str)
                }
            }
            offset += 1
            argCount += 1
        }

        if !args.isEmpty {
            return args.joined(separator: " ")
        }

        return resolveProcessName(pid: pid)
    }

    public static func resolveProcessName(pid: pid_t) -> String {
        var nameBuffer = [CChar](repeating: 0, count: 1024)
        let len = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        if len > 0 {
            let name = nameBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return name
            }
        }

        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
            return name
        }

        return "PID \(pid)"
    }

    public init(pid: pid_t, onExit: (@MainActor @Sendable (pid_t) -> Void)? = nil) throws {
        guard pid > 0 else {
            throw ProcessBindingError.invalidPID(pid)
        }
        guard Self.processExists(pid: pid) else {
            throw ProcessBindingError.processNotFound(pid)
        }

        self.pid = pid
        self.processName = Self.resolveProcessName(pid: pid)
        self.commandLine = Self.resolveCommandLine(pid: pid)
        self.fullPath = Self.resolveProcessPath(pid: pid)
        self.appIcon = NSRunningApplication(processIdentifier: pid)?.icon
        self.startDate = Date()
        self.onExit = onExit

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            Log.process.info("Observed exit of bound process \(self.processName) (PID: \(self.pid))")
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.onExit?(self.pid)
                self.cancel()
            }
        }
        source.resume()
        self.source = source

        Log.process.info("Bound process \(self.processName) (PID: \(pid))")
    }

    deinit {
        cancel()
    }

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        if let src = source {
            src.cancel()
            source = nil
        }
    }
}
