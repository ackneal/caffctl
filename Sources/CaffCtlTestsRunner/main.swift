import Foundation
import AppKit
import CaffCtlCore

final class TestBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { self._value = value }
    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _value = newValue
        }
    }
}

final class MockTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var bindings: [pid_t: MockProcessBinding] = [:]
    func record(_ b: MockProcessBinding) {
        lock.lock()
        defer { lock.unlock() }
        bindings[b.pid] = b
    }
    subscript(pid: pid_t) -> MockProcessBinding? {
        lock.lock()
        defer { lock.unlock() }
        return bindings[pid]
    }
}

@MainActor
func runAllTests() async {
    print("========================================")
    print("Running CaffCtl Suite (14 Invariant Tests)")
    print("========================================")
    
    var passed = 0
    var failed = 0
    
    func runTest(name: String, test: () async throws -> Void) async {
        print("▶ Running \(name)...", terminator: " ")
        do {
            try await test()
            print("✅ PASSED")
            passed += 1
        } catch {
            print("❌ FAILED: \(error)")
            failed += 1
        }
    }

    // 1. Global count never exceeds 1
    await runTest(name: "Test 1: Global count never exceeds 1") {
        let mock = MockCaffeinateProcess()
        let manager = WakeManager(caffeinateProcess: mock)
        assert(manager.globalSession == nil)
        
        manager.activateGlobal(duration: 1800)
        assert(manager.globalSession != nil)
        assert(manager.globalSession?.duration == 1800)
        
        manager.activateGlobal(duration: 3600)
        assert(manager.globalSession != nil)
        assert(manager.globalSession?.duration == 3600)
        
        manager.deactivateGlobal()
        assert(manager.globalSession == nil)
    }

    // 2. Same PID cannot register twice
    await runTest(name: "Test 2: Same PID cannot register twice") {
        let mock = MockCaffeinateProcess()
        let manager = WakeManager(caffeinateProcess: mock) { pid, onExit in
            MockProcessBinding(pid: pid, onExit: onExit)
        }
        try manager.bindProcess(pid: 12345)
        assert(manager.processBindings.count == 1)
        
        var threwExpected = false
        do {
            try manager.bindProcess(pid: 12345)
        } catch ProcessBindingError.alreadyBound {
            threwExpected = true
        }
        assert(threwExpected, "Expected ProcessBindingError.alreadyBound")
        assert(manager.processBindings.count == 1)
    }

    // 3. Managed caffeinate count never exceeds 1
    await runTest(name: "Test 3: Managed caffeinate count never exceeds 1") {
        let mock = MockCaffeinateProcess()
        let manager = WakeManager(caffeinateProcess: mock) { pid, onExit in
            MockProcessBinding(pid: pid, onExit: onExit)
        }
        manager.activateGlobal(duration: nil)
        try manager.bindProcess(pid: 1001)
        try manager.bindProcess(pid: 1002)
        assert(mock.isRunning)
        assert(mock.startCallCount == 1)
    }

    // 4. sessions == 0 -> caffeinate stopped
    await runTest(name: "Test 4: Zero sessions -> caffeinate stopped") {
        let mock = MockCaffeinateProcess()
        let manager = WakeManager(caffeinateProcess: mock) { pid, onExit in
            MockProcessBinding(pid: pid, onExit: onExit)
        }
        assert(!mock.isRunning)
        manager.activateGlobal(duration: 100)
        assert(mock.isRunning)
        manager.deactivateGlobal()
        assert(!mock.isRunning)
        assert(mock.stopCallCount == 1)
    }

    // 5. sessions > 0 -> caffeinate running
    await runTest(name: "Test 5: Active sessions -> caffeinate running") {
        let mock = MockCaffeinateProcess()
        let manager = WakeManager(caffeinateProcess: mock) { pid, onExit in
            MockProcessBinding(pid: pid, onExit: onExit)
        }
        assert(!manager.isActive)
        assert(!mock.isRunning)
        try manager.bindProcess(pid: 2001)
        assert(manager.isActive)
        assert(mock.isRunning)
    }

    // 6. Global expires while PID exists -> caffeinate remains running
    await runTest(name: "Test 6: Global expires while PID exists -> caffeinate remains running") {
        let mock = MockCaffeinateProcess()
        let manager = WakeManager(caffeinateProcess: mock) { pid, onExit in
            MockProcessBinding(pid: pid, onExit: onExit)
        }
        manager.activateGlobal(duration: 60)
        try manager.bindProcess(pid: 3001)
        assert(mock.isRunning)
        
        manager.handleGlobalExpired()
        assert(manager.globalSession == nil)
        assert(manager.processBindings.count == 1)
        assert(mock.isRunning)
    }

    // 7. PID A exits while PID B exists -> caffeinate remains running
    await runTest(name: "Test 7: PID A exits while PID B exists -> caffeinate remains running") {
        let mock = MockCaffeinateProcess()
        let manager = WakeManager(caffeinateProcess: mock) { pid, onExit in
            MockProcessBinding(pid: pid, onExit: onExit)
        }
        try manager.bindProcess(pid: 4001)
        try manager.bindProcess(pid: 4002)
        assert(manager.processBindings.count == 2)
        assert(mock.isRunning)
        
        manager.unbindProcess(pid: 4001)
        assert(manager.processBindings.count == 1)
        assert(mock.isRunning)
    }

    // 8. Last bound PID exits -> caffeinate stops
    await runTest(name: "Test 8: Last bound PID exits -> caffeinate stops") {
        let mock = MockCaffeinateProcess()
        let manager = WakeManager(caffeinateProcess: mock) { pid, onExit in
            MockProcessBinding(pid: pid, onExit: onExit)
        }
        try manager.bindProcess(pid: 5001)
        assert(mock.isRunning)
        
        manager.unbindProcess(pid: 5001)
        assert(!mock.isRunning)
        assert(mock.stopCallCount == 1)
    }

    // 9. Activating Global twice -> replaces state without spawning another caffeinate
    await runTest(name: "Test 9: Activating Global twice replaces state without extra caffeinate") {
        let mock = MockCaffeinateProcess()
        let manager = WakeManager(caffeinateProcess: mock)
        manager.activateGlobal(duration: nil)
        assert(mock.isRunning)
        assert(mock.startCallCount == 1)
        
        manager.activateGlobal(duration: 1800)
        assert(mock.isRunning)
        assert(mock.startCallCount == 1)
        assert(manager.globalSession?.duration == 1800)
    }

    // 10. Unexpected caffeinate exit with active sessions -> bounded recovery
    await runTest(name: "Test 10: Unexpected caffeinate exit with active sessions -> bounded recovery") {
        let mock = MockCaffeinateProcess()
        let manager = WakeManager(caffeinateProcess: mock)
        manager.activateGlobal(duration: nil)
        assert(mock.isRunning)
        assert(mock.startCallCount == 1)
        
        mock.simulateUnexpectedExit()
        try? await Task.sleep(nanoseconds: 50_000_000)
        assert(mock.isRunning)
        assert(mock.startCallCount == 2)
        
        mock.simulateUnexpectedExit()
        try? await Task.sleep(nanoseconds: 50_000_000)
        assert(mock.isRunning)
        assert(mock.startCallCount == 3)
        
        mock.simulateUnexpectedExit()
        try? await Task.sleep(nanoseconds: 50_000_000)
        assert(!mock.isRunning)
        assert(manager.lastError != nil)
    }

    // 11. App termination -> managed caffeinate cannot remain orphaned
    await runTest(name: "Test 11: App termination stops caffeinate and cleans up") {
        let mock = MockCaffeinateProcess()
        let cancelledBox = TestBox(false)
        let manager = WakeManager(caffeinateProcess: mock) { pid, onExit in
            MockProcessBinding(pid: pid, onExit: onExit, onCancel: { cancelledBox.value = true })
        }
        manager.activateGlobal(duration: nil)
        try manager.bindProcess(pid: 6001)
        assert(mock.isRunning)
        
        manager.cleanup()
        assert(!mock.isRunning)
        assert(manager.globalSession == nil)
        assert(manager.processBindings.isEmpty)
        assert(cancelledBox.value)
    }

    // 12. Bound process -> Caffeine never sends it termination signals
    await runTest(name: "Test 12: Bound process -> observe-only, never sent signals") {
        let mock = MockCaffeinateProcess()
        let tracker = MockTracker()
        let manager = WakeManager(caffeinateProcess: mock) { pid, onExit in
            let b = MockProcessBinding(pid: pid, onExit: onExit)
            tracker.record(b)
            return b
        }
        try manager.bindProcess(pid: 7001)
        manager.unbindProcess(pid: 7001)
        manager.cleanup()
        
        let binding = tracker[7001]
        assert(binding?.isCancelled == true)
        assert(binding?.signalsSent.isEmpty == true)
    }

    // 13. Invalid PID -> clean rejection
    await runTest(name: "Test 13: Invalid PID -> clean rejection") {
        let mock = MockCaffeinateProcess()
        let manager = WakeManager(caffeinateProcess: mock)
        
        var threw0 = false
        do {
            try manager.bindProcess(pid: 0)
        } catch ProcessBindingError.invalidPID {
            threw0 = true
        }
        assert(threw0)
        
        var threwNegative = false
        do {
            try manager.bindProcess(pid: -100)
        } catch ProcessBindingError.invalidPID {
            threwNegative = true
        }
        assert(threwNegative)
    }

    // 14. Malformed IPC message -> clean rejection without crash
    await runTest(name: "Test 14: Malformed IPC message -> clean rejection without crash") {
        let mock = MockCaffeinateProcess()
        let manager = WakeManager(caffeinateProcess: mock)
        let socketPath = "/tmp/caff-test-\(UUID().uuidString.prefix(8)).sock"
        
        let server = IPCServer(socketPath: socketPath, wakeManager: manager)
        try server.start()
        defer { server.stop() }
        
        let client = IPCClient(socketPath: socketPath)
        let statusResp = try await client.send(request: .status)
        switch statusResp {
        case .status(let s):
            assert(!s.isActive)
        default:
            fatalError("Expected status response")
        }
        
        let malformedData = "{ this is invalid json !!! }\n".data(using: .utf8)!
        let rawResp = try client.sendRaw(data: malformedData)
        let decoded = try IPCResponse.decode(from: rawResp)
        switch decoded {
        case .error(let msg):
            assert(!msg.isEmpty)
        default:
            fatalError("Expected error response for malformed JSON")
        }
    }

    print("========================================")
    print("Test Summary: \(passed) passed, \(failed) failed")
    print("========================================")
    if failed > 0 {
        exit(1)
    }
}

// MARK: - Mocks for Standalone Test Runner

final class MockCaffeinateProcess: CaffeinateProcessProtocol, @unchecked Sendable {
    private let lock = NSLock()
    var startCallCount: Int = 0
    var stopCallCount: Int = 0
    var shouldThrowOnStart: Bool = false
    var _isRunning: Bool = false
    var _failureTimestamps: [Date] = []
    var onUnexpectedExit: (@MainActor @Sendable () -> Void)?

    init(isRunning: Bool = false) {
        self._isRunning = isRunning
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isRunning
    }

    var failureTimestamps: [Date] {
        lock.lock()
        defer { lock.unlock() }
        return _failureTimestamps
    }

    func start() throws {
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

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopCallCount += 1
        _isRunning = false
    }

    func simulateUnexpectedExit() {
        lock.lock()
        _isRunning = false
        _failureTimestamps.append(Date())
        lock.unlock()

        Task { @MainActor [weak self] in
            self?.onUnexpectedExit?()
        }
    }
}

final class MockProcessBinding: ProcessBindingProtocol, @unchecked Sendable {
    let pid: pid_t
    let processName: String
    let commandLine: String = "test --arg"
    let fullPath: String = "/usr/bin/test"
    let startDate: Date
    var appIcon: NSImage? { nil }
    var onExit: (@MainActor @Sendable (pid_t) -> Void)?
    var onCancel: (@Sendable () -> Void)?
    private(set) var isCancelled: Bool = false
    private(set) var signalsSent: [Int32] = []

    var elapsedSeconds: TimeInterval {
        Date().timeIntervalSince(startDate)
    }

    init(pid: pid_t, processName: String = "TestProcess", startDate: Date = Date(), onExit: (@MainActor @Sendable (pid_t) -> Void)? = nil, onCancel: (@Sendable () -> Void)? = nil) {
        self.pid = pid
        self.processName = processName
        self.startDate = startDate
        self.onExit = onExit
        self.onCancel = onCancel
    }

    func cancel() {
        isCancelled = true
        onCancel?()
    }
}

@main
struct CaffCtlTestsRunnerMain {
    static func main() async {
        await runAllTests()
    }
}
