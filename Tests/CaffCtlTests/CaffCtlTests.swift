import Testing
import Foundation
import AppKit
@testable import CaffCtlCore

// MARK: - Mocks

public final class MockCaffeinateProcess: CaffeinateProcessProtocol, @unchecked Sendable {
    private let lock = NSLock()
    public var startCallCount: Int = 0
    public var stopCallCount: Int = 0
    public var shouldThrowOnStart: Bool = false
    public var _isRunning: Bool = false
    public var _failureTimestamps: [Date] = []
    public var onUnexpectedExit: (@MainActor @Sendable () -> Void)?

    public init(isRunning: Bool = false) {
        self._isRunning = isRunning
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isRunning
    }

    public var failureTimestamps: [Date] {
        lock.lock()
        defer { lock.unlock() }
        return _failureTimestamps
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }

        startCallCount += 1
        if shouldThrowOnStart {
            throw CaffeinateError.launchFailed("Mock launch failure")
        }
        let now = Date()
        _failureTimestamps = _failureTimestamps.filter { now.timeIntervalSince($0) <= 10.0 }
        if _failureTimestamps.count >= 3 {
            throw CaffeinateError.restartLimitExceeded
        }
        _isRunning = true
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopCallCount += 1
        _isRunning = false
    }

    public func simulateUnexpectedExit() {
        lock.lock()
        _isRunning = false
        _failureTimestamps.append(Date())
        lock.unlock()

        Task { @MainActor [weak self] in
            self?.onUnexpectedExit?()
        }
    }
}

public final class MockProcessBinding: ProcessBindingProtocol, @unchecked Sendable {
    public let pid: pid_t
    public let processName: String
    public let commandLine: String = "test --arg"
    public let fullPath: String = "/usr/bin/test"
    public let startDate: Date
    public var appIcon: NSImage? { nil }
    public var onExit: (@MainActor @Sendable (pid_t) -> Void)?
    public private(set) var isCancelled: Bool = false
    public private(set) var signalsSent: [Int32] = []

    public var elapsedSeconds: TimeInterval {
        Date().timeIntervalSince(startDate)
    }

    public init(pid: pid_t, processName: String = "TestProcess", startDate: Date = Date(), onExit: (@MainActor @Sendable (pid_t) -> Void)? = nil) {
        self.pid = pid
        self.processName = processName
        self.startDate = startDate
        self.onExit = onExit
    }

    public func cancel() {
        isCancelled = true
    }

    public func simulateExit() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.onExit?(self.pid)
            self.cancel()
        }
    }

    public func recordSignal(_ sig: Int32) {
        signalsSent.append(sig)
    }
}

public final class BindingTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var bindings: [pid_t: MockProcessBinding] = [:]

    public init() {}

    public func record(_ binding: MockProcessBinding) {
        lock.lock()
        defer { lock.unlock() }
        bindings[binding.pid] = binding
    }

    public subscript(pid: pid_t) -> MockProcessBinding? {
        lock.lock()
        defer { lock.unlock() }
        return bindings[pid]
    }
}

// MARK: - Test Suite

@Suite struct CaffCtlTests {

    // Test 1: Global count never exceeds 1
    @Test @MainActor
    func test1_globalCountNeverExceedsOne() {
        let mockCaffeinate = MockCaffeinateProcess()
        let manager = WakeManager(caffeinateProcess: mockCaffeinate)

        #expect(manager.globalSession == nil)

        manager.activateGlobal(duration: 1800)
        #expect(manager.globalSession != nil)
        #expect(manager.globalSession?.duration == 1800)

        // Activating again replaces the single session
        manager.activateGlobal(duration: 3600)
        #expect(manager.globalSession != nil)
        #expect(manager.globalSession?.duration == 3600)

        manager.deactivateGlobal()
        #expect(manager.globalSession == nil)
    }

    // Test 2: Same PID cannot register twice
    @Test @MainActor
    func test2_samePidCannotRegisterTwice() {
        let mockCaffeinate = MockCaffeinateProcess()
        let manager = WakeManager(caffeinateProcess: mockCaffeinate) { pid, onExit in
            MockProcessBinding(pid: pid, onExit: onExit)
        }

        #expect(throws: Never.self) {
            try manager.bindProcess(pid: 12345)
        }
        #expect(manager.processBindings.count == 1)

        // Second registration of same PID must throw alreadyBound
        #expect(throws: ProcessBindingError.alreadyBound(12345)) {
            try manager.bindProcess(pid: 12345)
        }
        #expect(manager.processBindings.count == 1)
    }

    // Test 3: Managed caffeinate count never exceeds 1
    @Test @MainActor
    func test3_managedCaffeinateCountNeverExceedsOne() {
        let mockCaffeinate = MockCaffeinateProcess()
        let manager = WakeManager(caffeinateProcess: mockCaffeinate) { pid, onExit in
            MockProcessBinding(pid: pid, onExit: onExit)
        }

        manager.activateGlobal(duration: nil)
        try? manager.bindProcess(pid: 1001)
        try? manager.bindProcess(pid: 1002)

        #expect(mockCaffeinate.isRunning)
        #expect(mockCaffeinate.startCallCount == 1)
    }

    // Test 4: sessions == 0 -> caffeinate stopped
    @Test @MainActor
    func test4_zeroSessionsCaffeinateStopped() {
        let mockCaffeinate = MockCaffeinateProcess()
        let manager = WakeManager(caffeinateProcess: mockCaffeinate) { pid, onExit in
            MockProcessBinding(pid: pid, onExit: onExit)
        }

        #expect(!mockCaffeinate.isRunning)
        manager.activateGlobal(duration: 100)
        #expect(mockCaffeinate.isRunning)

        manager.deactivateGlobal()
        #expect(!mockCaffeinate.isRunning)
        #expect(mockCaffeinate.stopCallCount == 1)
    }

    // Test 5: sessions > 0 -> caffeinate running
    @Test @MainActor
    func test5_activeSessionsCaffeinateRunning() {
        let mockCaffeinate = MockCaffeinateProcess()
        let manager = WakeManager(caffeinateProcess: mockCaffeinate) { pid, onExit in
            MockProcessBinding(pid: pid, onExit: onExit)
        }

        #expect(!manager.isActive)
        #expect(!mockCaffeinate.isRunning)

        try? manager.bindProcess(pid: 2001)
        #expect(manager.isActive)
        #expect(mockCaffeinate.isRunning)
    }

    // Test 6: Global expires while PID exists -> caffeinate remains running
    @Test @MainActor
    func test6_globalExpiresWhilePIDExistsCaffeinateRemainsRunning() {
        let mockCaffeinate = MockCaffeinateProcess()
        let manager = WakeManager(caffeinateProcess: mockCaffeinate) { pid, onExit in
            MockProcessBinding(pid: pid, onExit: onExit)
        }

        manager.activateGlobal(duration: 60)
        try? manager.bindProcess(pid: 3001)
        #expect(mockCaffeinate.isRunning)

        manager.handleGlobalExpired()
        #expect(manager.globalSession == nil)
        #expect(manager.processBindings.count == 1)
        #expect(mockCaffeinate.isRunning)
    }

    // Test 7: PID A exits while PID B exists -> caffeinate remains running
    @Test @MainActor
    func test7_pidAExitsWhilePIDBExistsCaffeinateRemainsRunning() {
        let mockCaffeinate = MockCaffeinateProcess()
        let tracker = BindingTracker()
        let manager = WakeManager(caffeinateProcess: mockCaffeinate) { pid, onExit in
            let binding = MockProcessBinding(pid: pid, onExit: onExit)
            tracker.record(binding)
            return binding
        }

        try? manager.bindProcess(pid: 4001)
        try? manager.bindProcess(pid: 4002)
        #expect(manager.processBindings.count == 2)
        #expect(mockCaffeinate.isRunning)

        manager.unbindProcess(pid: 4001)
        #expect(manager.processBindings.count == 1)
        #expect(mockCaffeinate.isRunning)
    }

    // Test 8: Last bound PID exits -> caffeinate stops
    @Test @MainActor
    func test8_lastBoundPIDExitsCaffeinateStops() {
        let mockCaffeinate = MockCaffeinateProcess()
        let manager = WakeManager(caffeinateProcess: mockCaffeinate) { pid, onExit in
            MockProcessBinding(pid: pid, onExit: onExit)
        }

        try? manager.bindProcess(pid: 5001)
        #expect(mockCaffeinate.isRunning)

        manager.unbindProcess(pid: 5001)
        #expect(!mockCaffeinate.isRunning)
        #expect(mockCaffeinate.stopCallCount == 1)
    }

    // Test 9: Activating Global twice -> replaces state without spawning another caffeinate
    @Test @MainActor
    func test9_activateGlobalTwiceReplacesStateWithoutSpawningExtraCaffeinate() {
        let mockCaffeinate = MockCaffeinateProcess()
        let manager = WakeManager(caffeinateProcess: mockCaffeinate)

        manager.activateGlobal(duration: nil)
        #expect(mockCaffeinate.isRunning)
        #expect(mockCaffeinate.startCallCount == 1)

        manager.activateGlobal(duration: 1800)
        #expect(mockCaffeinate.isRunning)
        #expect(mockCaffeinate.startCallCount == 1)
        #expect(manager.globalSession?.duration == 1800)
    }

    // Test 10: Unexpected caffeinate exit with active sessions -> bounded recovery
    @Test @MainActor
    func test10_unexpectedCaffeinateExitBoundedRecovery() async {
        let mockCaffeinate = MockCaffeinateProcess()
        let manager = WakeManager(caffeinateProcess: mockCaffeinate)

        manager.activateGlobal(duration: nil)
        #expect(mockCaffeinate.isRunning)
        #expect(mockCaffeinate.startCallCount == 1)

        // 1st unexpected exit -> should recover (restart count 2)
        mockCaffeinate.simulateUnexpectedExit()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(mockCaffeinate.isRunning)
        #expect(mockCaffeinate.startCallCount == 2)

        // 2nd unexpected exit -> should recover (restart count 3)
        mockCaffeinate.simulateUnexpectedExit()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(mockCaffeinate.isRunning)
        #expect(mockCaffeinate.startCallCount == 3)

        // 3rd unexpected exit -> exceeds threshold (3 recent failures), should not restart
        mockCaffeinate.simulateUnexpectedExit()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(!mockCaffeinate.isRunning)
        #expect(manager.lastError != nil)
    }

    // Test 11: App termination -> managed caffeinate cannot remain orphaned
    @Test @MainActor
    func test11_appTerminationStopsCaffeinateAndCancelsBindings() {
        let mockCaffeinate = MockCaffeinateProcess()
        let tracker = BindingTracker()
        let manager = WakeManager(caffeinateProcess: mockCaffeinate) { pid, onExit in
            let binding = MockProcessBinding(pid: pid, onExit: onExit)
            tracker.record(binding)
            return binding
        }

        manager.activateGlobal(duration: nil)
        try? manager.bindProcess(pid: 6001)
        #expect(mockCaffeinate.isRunning)

        manager.cleanup()
        #expect(!mockCaffeinate.isRunning)
        #expect(manager.globalSession == nil)
        #expect(manager.processBindings.isEmpty)
        #expect(tracker[6001]?.isCancelled == true)
    }

    // Test 12: Bound process -> Caffeine never sends it termination signals
    @Test @MainActor
    func test12_caffeineNeverSendsSignalsToBoundProcess() {
        let mockCaffeinate = MockCaffeinateProcess()
        let tracker = BindingTracker()
        let manager = WakeManager(caffeinateProcess: mockCaffeinate) { pid, onExit in
            let b = MockProcessBinding(pid: pid, onExit: onExit)
            tracker.record(b)
            return b
        }

        try? manager.bindProcess(pid: 7001)
        manager.unbindProcess(pid: 7001)
        manager.cleanup()

        guard let binding = tracker[7001] else {
            Issue.record("Binding was not created")
            return
        }

        #expect(binding.isCancelled)
        #expect(binding.signalsSent.isEmpty, "Signals were sent to bound PID, violating observe-only constraint!")
    }

    // Test 13: Invalid PID -> clean rejection
    @Test @MainActor
    func test13_invalidPIDCleanRejection() {
        let mockCaffeinate = MockCaffeinateProcess()
        let manager = WakeManager(caffeinateProcess: mockCaffeinate)

        #expect(throws: ProcessBindingError.invalidPID(0)) {
            try manager.bindProcess(pid: 0)
        }

        #expect(throws: ProcessBindingError.invalidPID(-100)) {
            try manager.bindProcess(pid: -100)
        }
    }

    @Test @MainActor
    func trackedGlobalCaffeinateDoesNotStartManagedAssertion() throws {
        let mockCaffeinate = MockCaffeinateProcess()
        let manager = WakeManager(caffeinateProcess: mockCaffeinate) { pid, onExit in
            MockProcessBinding(pid: pid, onExit: onExit)
        }

        try manager.trackGlobal(pid: 8000, duration: 3)

        #expect(manager.globalSession?.duration == 3)
        #expect(manager.processBindings.isEmpty)
        #expect(!mockCaffeinate.isRunning)
        #expect(mockCaffeinate.startCallCount == 0)
        #expect(manager.statusInfo.caffeinateRunning)
    }

    @Test @MainActor
    func trackedCaffeinateDoesNotStartManagedAssertion() throws {
        let mockCaffeinate = MockCaffeinateProcess()
        let manager = WakeManager(caffeinateProcess: mockCaffeinate) { pid, onExit in
            MockProcessBinding(pid: pid, onExit: onExit)
        }

        try manager.trackCaffeinate(pid: 8001)

        #expect(manager.isActive)
        #expect(!mockCaffeinate.isRunning)
        #expect(mockCaffeinate.startCallCount == 0)
        #expect(manager.statusInfo.caffeinateRunning)

        manager.unbindProcess(pid: 8001)
        #expect(!manager.isActive)
        #expect(!manager.statusInfo.caffeinateRunning)
    }

    // Test 14: Malformed IPC message -> clean rejection without crash
    @Test @MainActor
    func test14_malformedIPCMessageCleanRejection() async throws {
        let mockCaffeinate = MockCaffeinateProcess()
        let manager = WakeManager(caffeinateProcess: mockCaffeinate)
        let socketPath = "/tmp/caff-test-\(UUID().uuidString.prefix(8)).sock"

        let server = IPCServer(socketPath: socketPath, wakeManager: manager)
        try server.start()
        defer { server.stop() }

        let client = IPCClient(socketPath: socketPath)

        // Send valid status request
        let statusResponse = try await client.send(request: .status)
        switch statusResponse {
        case .status(let payload):
            #expect(!payload.isActive)
        default:
            Issue.record("Expected status response, got \(statusResponse)")
        }

        // Send malformed raw JSON bytes
        let malformedData = "{ this is definitely not valid json !!! }\n".data(using: .utf8)!
        let rawResponse = try client.sendRaw(data: malformedData)
        let decodedResponse = try IPCResponse.decode(from: rawResponse)

        switch decodedResponse {
        case .error(let msg):
            #expect(msg.contains("Malformed") || msg.contains("dataCorrupted") || !msg.isEmpty)
        default:
            Issue.record("Expected error response for malformed request, got \(decodedResponse)")
        }
    }
}
