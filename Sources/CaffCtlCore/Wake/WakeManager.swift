import Foundation
import os

@MainActor
public final class WakeManager: ObservableObject {
    @Published public private(set) var globalSession: GlobalSession?
    @Published public private(set) var processBindings: [pid_t: any ProcessBindingProtocol] = [:]
    @Published public private(set) var lastError: String?
    public private(set) var globalClientBinding: (any ProcessBindingProtocol)?

    public let caffeinateProcess: any CaffeinateProcessProtocol
    private var expiryTask: Task<Void, Never>?
    private let bindingFactory: @Sendable (pid_t, @MainActor @Sendable @escaping (pid_t) -> Void) throws -> any ProcessBindingProtocol

    public init(
        caffeinateProcess: any CaffeinateProcessProtocol = CaffeinateProcess(),
        bindingFactory: (@Sendable (pid_t, @MainActor @Sendable @escaping (pid_t) -> Void) throws -> any ProcessBindingProtocol)? = nil
    ) {
        self.caffeinateProcess = caffeinateProcess
        if let factory = bindingFactory {
            self.bindingFactory = factory
        } else {
            self.bindingFactory = { pid, onExit in
                try ProcessBinding(pid: pid, onExit: onExit)
            }
        }

        self.caffeinateProcess.onUnexpectedExit = { [weak self] in
            guard let self = self else { return }
            Log.wake.warning("caffeinate exited unexpectedly, reconciling...")
            self.reconcile()
        }
    }

    public var isActive: Bool {
        let hasGlobal = globalSession != nil && !globalSession!.isExpired
        let hasProcesses = !processBindings.isEmpty
        return hasGlobal || hasProcesses
    }

    public var statusInfo: StatusPayload {
        let globalInfo = globalSession.map {
            GlobalStatusInfo(
                duration: $0.duration,
                startDate: $0.startDate,
                expiryDate: $0.expiryDate,
                remainingSeconds: $0.remainingSeconds
            )
        }
        let procInfos = processBindings.values.map {
            ProcessStatusInfo(pid: $0.pid, name: $0.processName, startDate: $0.startDate, elapsedSeconds: $0.elapsedSeconds)
        }.sorted { $0.pid < $1.pid }

        return StatusPayload(
            isActive: isActive,
            global: globalInfo,
            processes: procInfos,
            caffeinateRunning: caffeinateProcess.isRunning,
            lastError: lastError
        )
    }

    public func reconcile() {
        if let session = globalSession, session.isExpired {
            expiryTask?.cancel()
            expiryTask = nil
            globalSession = nil
        }

        if isActive {
            if !caffeinateProcess.isRunning {
                do {
                    try caffeinateProcess.start()
                    lastError = nil
                    Log.wake.info("Reconciliation started caffeinate successfully")
                } catch {
                    lastError = error.localizedDescription
                    Log.wake.error("Reconciliation failed to start caffeinate: \(error.localizedDescription)")
                }
            }
        } else if caffeinateProcess.isRunning {
            caffeinateProcess.stop()
            Log.wake.info("Reconciliation stopped caffeinate successfully")
        }
    }

    public func activateGlobal(duration: TimeInterval?, clientPID: pid_t? = nil) {
        expiryTask?.cancel()
        expiryTask = nil
        globalClientBinding?.cancel()
        globalClientBinding = nil

        let session = GlobalSession(duration: duration)
        self.globalSession = session
        self.lastError = nil

        if let pid = clientPID, pid > 0 {
            do {
                self.globalClientBinding = try bindingFactory(pid) { [weak self] _ in
                    self?.deactivateGlobal()
                }
            } catch {
                Log.wake.error("Failed to monitor global client PID \(pid): \(error.localizedDescription)")
            }
        }

        Log.wake.info("Activated global session (duration: \(duration.map { "\($0)s" } ?? "indefinite"), clientPID: \(clientPID.map(String.init) ?? "none"))")

        if let duration = duration, duration > 0 {
            expiryTask = Task { [weak self] in
                let nanos = UInt64(duration * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                guard !Task.isCancelled else { return }
                self?.handleGlobalExpired()
            }
        }

        reconcile()
    }

    public func deactivateGlobal() {
        cancelGlobalSession(reason: "Deactivated global session")
    }

    public func handleGlobalExpired() {
        cancelGlobalSession(reason: "Global session expired")
    }

    private func cancelGlobalSession(reason: String) {
        expiryTask?.cancel()
        expiryTask = nil
        globalSession = nil

        if let client = globalClientBinding {
            let pid = client.pid
            globalClientBinding = nil
            client.cancel()
            kill(pid, SIGTERM)
        }

        Log.wake.info("\(reason)")
        reconcile()
    }

    public func bindProcess(pid: pid_t) throws {
        guard pid > 0 else {
            throw ProcessBindingError.invalidPID(pid)
        }
        guard processBindings[pid] == nil else {
            throw ProcessBindingError.alreadyBound(pid)
        }

        let binding = try bindingFactory(pid) { [weak self] exitedPid in
            self?.unbindProcess(pid: exitedPid)
        }
        processBindings[pid] = binding
        Log.wake.info("Successfully bound PID \(pid) (\(binding.processName))")
        reconcile()
    }

    public func unbindProcess(pid: pid_t) {
        if let binding = processBindings.removeValue(forKey: pid) {
            binding.cancel()
            Log.wake.info("Unbound PID \(pid)")
            reconcile()
        }
    }

    private func cancelAllBindings() {
        for (_, binding) in processBindings {
            binding.cancel()
        }
        processBindings.removeAll()
    }

    public func stopAll() {
        expiryTask?.cancel()
        expiryTask = nil
        if let client = globalClientBinding {
            let pid = client.pid
            globalClientBinding = nil
            client.cancel()
            kill(pid, SIGTERM)
        }
        globalSession = nil
        cancelAllBindings()
        reconcile()
    }

    public func cleanup() {
        expiryTask?.cancel()
        expiryTask = nil
        if let client = globalClientBinding {
            let pid = client.pid
            globalClientBinding = nil
            client.cancel()
            kill(pid, SIGTERM)
        }
        cancelAllBindings()
        globalSession = nil
        caffeinateProcess.stop()
        Log.wake.info("WakeManager cleanup finished")
    }
}
