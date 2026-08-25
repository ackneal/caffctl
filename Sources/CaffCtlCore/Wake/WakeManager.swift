import Foundation
import os

@MainActor
public final class WakeManager: ObservableObject {
    @Published public private(set) var globalSession: GlobalSession?
    @Published public private(set) var processBindings: [pid_t: any ProcessBindingProtocol] = [:]
    @Published public private(set) var lastError: String?
    public private(set) var globalClientBinding: (any ProcessBindingProtocol)?

    public let caffeinateProcess: any CaffeinateProcessProtocol
    private var globalUsesTrackedCaffeinate = false
    private var trackedCaffeinatePIDs: Set<pid_t> = []
    private var expiryTask: Task<Void, Never>?
    private let bindingFactory: @Sendable (pid_t, @MainActor @Sendable @escaping (pid_t) -> Void) throws -> any ProcessBindingProtocol
    private let signalSender: @Sendable (pid_t, Int32) -> Void

    public convenience init(
        caffeinateProcess: any CaffeinateProcessProtocol = CaffeinateProcess(),
        bindingFactory: (@Sendable (pid_t, @MainActor @Sendable @escaping (pid_t) -> Void) throws -> any ProcessBindingProtocol)? = nil
    ) {
        self.init(
            caffeinateProcess: caffeinateProcess,
            bindingFactory: bindingFactory,
            signalSender: { pid, signal in kill(pid, signal) }
        )
    }

    public convenience init(
        caffeinateProcess: any CaffeinateProcessProtocol,
        signalSender: @escaping @Sendable (pid_t, Int32) -> Void,
        bindingFactory: @escaping @Sendable (pid_t, @MainActor @Sendable @escaping (pid_t) -> Void) throws -> any ProcessBindingProtocol
    ) {
        self.init(
            caffeinateProcess: caffeinateProcess,
            bindingFactory: bindingFactory,
            signalSender: signalSender
        )
    }

    private init(
        caffeinateProcess: any CaffeinateProcessProtocol,
        bindingFactory: (@Sendable (pid_t, @MainActor @Sendable @escaping (pid_t) -> Void) throws -> any ProcessBindingProtocol)?,
        signalSender: @escaping @Sendable (pid_t, Int32) -> Void
    ) {
        self.caffeinateProcess = caffeinateProcess
        self.signalSender = signalSender
        self.bindingFactory = bindingFactory ?? { pid, onExit in
            try ProcessBinding(pid: pid, onExit: onExit)
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
            caffeinateRunning: caffeinateProcess.isRunning || globalUsesTrackedCaffeinate || !trackedCaffeinatePIDs.isEmpty,
            lastError: lastError
        )
    }

    public func reconcile() {
        if let session = globalSession, session.isExpired {
            expiryTask?.cancel()
            expiryTask = nil
            globalSession = nil
        }

        let needsManagedAssertion = (globalSession != nil && !globalUsesTrackedCaffeinate)
            || processBindings.keys.contains { !trackedCaffeinatePIDs.contains($0) }

        if needsManagedAssertion {
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
        clearGlobalClient()
        globalUsesTrackedCaffeinate = false

        let session = GlobalSession(duration: duration)
        self.globalSession = session
        self.lastError = nil

        if let pid = clientPID, pid > 0 {
            do {
                self.globalClientBinding = try bindingFactory(pid) { [weak self] _ in
                    self?.handleGlobalClientExit()
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

    public func trackGlobal(pid: pid_t, duration: TimeInterval?) throws {
        guard pid > 0 else {
            throw ProcessBindingError.invalidPID(pid)
        }

        let binding = try bindingFactory(pid) { [weak self] _ in
            self?.handleGlobalClientExit()
        }

        clearGlobalClient()
        globalUsesTrackedCaffeinate = true
        globalSession = GlobalSession(duration: duration)
        globalClientBinding = binding
        lastError = nil
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

        clearGlobalClient()
        globalUsesTrackedCaffeinate = false

        Log.wake.info("\(reason)")
        reconcile()
    }

    private func handleGlobalClientExit() {
        expiryTask?.cancel()
        expiryTask = nil
        globalClientBinding?.cancel()
        globalClientBinding = nil
        globalSession = nil
        globalUsesTrackedCaffeinate = false
        reconcile()
    }

    private func clearGlobalClient() {
        expiryTask?.cancel()
        expiryTask = nil
        guard let client = globalClientBinding else { return }

        globalClientBinding = nil
        client.cancel()
        signalSender(client.pid, SIGTERM)
    }

    public func bindProcess(pid: pid_t) throws {
        guard pid > 0 else {
            throw ProcessBindingError.invalidPID(pid)
        }
        guard processBindings[pid] == nil else {
            throw ProcessBindingError.alreadyBound(pid)
        }

        let binding = try bindingFactory(pid) { [weak self] exitedPid in
            self?.removeBinding(pid: exitedPid, terminateTrackedCaffeinate: false)
        }
        processBindings[pid] = binding
        Log.wake.info("Successfully bound PID \(pid)")
        reconcile()
    }

    public func trackCaffeinate(pid: pid_t) throws {
        trackedCaffeinatePIDs.insert(pid)
        do {
            try bindProcess(pid: pid)
        } catch {
            trackedCaffeinatePIDs.remove(pid)
            throw error
        }
    }

    public func unbindProcess(pid: pid_t) {
        removeBinding(pid: pid, terminateTrackedCaffeinate: true)
    }

    private func removeBinding(pid: pid_t, terminateTrackedCaffeinate: Bool) {
        guard let binding = processBindings.removeValue(forKey: pid) else { return }

        let isTrackedCaffeinate = trackedCaffeinatePIDs.remove(pid) != nil
        binding.cancel()
        if terminateTrackedCaffeinate && isTrackedCaffeinate {
            signalSender(pid, SIGTERM)
        }
        Log.wake.info("Unbound PID \(pid)")
        reconcile()
    }

    private func cancelAllBindings() {
        for (pid, binding) in processBindings {
            binding.cancel()
            if trackedCaffeinatePIDs.contains(pid) {
                signalSender(pid, SIGTERM)
            }
        }
        processBindings.removeAll()
        trackedCaffeinatePIDs.removeAll()
    }

    public func stopAll() {
        expiryTask?.cancel()
        expiryTask = nil
        clearGlobalClient()
        globalUsesTrackedCaffeinate = false
        globalSession = nil
        cancelAllBindings()
        reconcile()
    }

    public func cleanup() {
        expiryTask?.cancel()
        expiryTask = nil
        clearGlobalClient()
        globalUsesTrackedCaffeinate = false
        cancelAllBindings()
        globalSession = nil
        caffeinateProcess.stop()
        Log.wake.info("WakeManager cleanup finished")
    }
}
