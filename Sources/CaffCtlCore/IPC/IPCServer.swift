import Foundation
import Darwin
import os

public enum IPCServerError: LocalizedError, Sendable, Equatable {
    case socketCreationFailed(Int32)
    case socketPathTooLong
    case bindFailed(Int32)
    case listenFailed(Int32)
    case directoryCreationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let code):
            return "Failed to create UNIX socket (errno: \(code))."
        case .socketPathTooLong:
            return "UNIX socket path exceeds system maximum length."
        case .bindFailed(let code):
            return "Failed to bind UNIX socket (errno: \(code))."
        case .listenFailed(let code):
            return "Failed to listen on UNIX socket (errno: \(code))."
        case .directoryCreationFailed(let msg):
            return "Failed to create socket directory: \(msg)"
        }
    }
}

public final class IPCServer: @unchecked Sendable {
    public static var defaultSocketPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("CaffCtl/run/control.sock").path
    }

    public let socketPath: String
    private let wakeManager: WakeManager
    private let serverQueue = DispatchQueue(label: "com.caffctl.ipc.server", qos: .userInitiated)
    private var listeningSource: (any DispatchSourceRead)?
    private var serverFd: Int32 = -1
    private let lock = NSLock()
    private var isRunning = false

    public init(socketPath: String = IPCServer.defaultSocketPath, wakeManager: WakeManager) {
        self.socketPath = socketPath
        self.wakeManager = wakeManager
    }

    deinit {
        stop()
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }

        let parentDir = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            // Ensure parent directory permissions are 0700 (S_IRWXU)
            chmod(parentDir.path, S_IRWXU)
        } catch {
            throw IPCServerError.directoryCreationFailed(error.localizedDescription)
        }

        // Remove any stale socket file
        unlink(socketPath)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IPCServerError.socketCreationFailed(errno)
        }

        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let pathCString = socketPath.utf8CString
        let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathCString.count <= sunPathCapacity else {
            Darwin.close(fd)
            throw IPCServerError.socketPathTooLong
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: sunPathCapacity) { dest in
                pathCString.withUnsafeBufferPointer { src in
                    dest.initialize(from: src.baseAddress!, count: src.count)
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, addrLen)
            }
        }

        guard bindResult == 0 else {
            let err = errno
            Darwin.close(fd)
            throw IPCServerError.bindFailed(err)
        }

        // Ensure socket file permissions are 0600 (S_IRUSR | S_IWUSR)
        chmod(socketPath, S_IRUSR | S_IWUSR)

        guard Darwin.listen(fd, SOMAXCONN) == 0 else {
            let err = errno
            Darwin.close(fd)
            unlink(socketPath)
            throw IPCServerError.listenFailed(err)
        }

        self.serverFd = fd
        self.isRunning = true

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: serverQueue)
        source.setEventHandler { [weak self] in
            self?.acceptConnections()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        self.listeningSource = source

        Log.ipc.info("IPC Server listening on \(self.socketPath)")
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard isRunning else { return }
        isRunning = false

        if let source = listeningSource {
            source.cancel()
            listeningSource = nil
        } else if serverFd >= 0 {
            Darwin.close(serverFd)
            serverFd = -1
        }

        unlink(socketPath)
        Log.ipc.info("IPC Server stopped")
    }

    private func acceptConnections() {
        while true {
            let clientFd = Darwin.accept(serverFd, nil, nil)
            guard clientFd >= 0 else {
                break
            }

            let flags = fcntl(clientFd, F_GETFL, 0)
            if flags >= 0 {
                _ = fcntl(clientFd, F_SETFL, flags | O_NONBLOCK)
            }
            var noSigPipe: Int32 = 1
            setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            handleClientConnection(clientFd: clientFd)
        }
    }

    private func handleClientConnection(clientFd: Int32) {
        let clientSource = DispatchSource.makeReadSource(fileDescriptor: clientFd, queue: serverQueue)
        var receivedData = Data()

        clientSource.setEventHandler { [weak self] in
            guard let self = self else {
                clientSource.cancel()
                return
            }

            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = Darwin.read(clientFd, &buffer, buffer.count)

            if bytesRead > 0 {
                receivedData.append(buffer, count: bytesRead)
                if let newlineIndex = receivedData.firstIndex(of: UInt8(ascii: "\n")) {
                    let requestData = receivedData.prefix(upTo: newlineIndex)
                    clientSource.cancel()
                    self.processClientRequest(data: Data(requestData), clientFd: clientFd)
                }
            } else if bytesRead == 0 {
                // Client closed stream
                clientSource.cancel()
                if !receivedData.isEmpty {
                    self.processClientRequest(data: receivedData, clientFd: clientFd)
                } else {
                    Darwin.close(clientFd)
                }
            } else {
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    clientSource.cancel()
                    Darwin.close(clientFd)
                }
            }
        }


        clientSource.resume()
    }

    private func processClientRequest(data: Data, clientFd: Int32) {
        Task {
            let response: IPCResponse
            do {
                let request = try IPCRequest.decode(from: data)
                response = await self.executeRequest(request)
            } catch {
                Log.ipc.error("Malformed IPC request received: \(error.localizedDescription)")
                response = .error(message: "Malformed request: \(error.localizedDescription)")
            }

            self.sendResponseAndClose(response: response, clientFd: clientFd)
        }
    }

    @MainActor
    private func executeRequest(_ request: IPCRequest) -> IPCResponse {
        switch request {
        case .activateGlobal(let duration, let clientPID):
            wakeManager.activateGlobal(duration: duration, clientPID: clientPID)
            let durStr = duration.map { "\($0)s" } ?? "indefinite"
            return .ok(message: "Activated global wake session (\(durStr))")

        case .trackGlobal(let pid, let duration):
            do {
                try wakeManager.trackGlobal(pid: pid, duration: duration)
                return .ok(message: "Tracking global caffeinate (PID: \(pid))")
            } catch {
                return .error(message: error.localizedDescription)
            }

        case .deactivateGlobal:
            wakeManager.deactivateGlobal()
            return .ok(message: "Deactivated global wake session")

        case .bindProcess(let pid):
            do {
                try wakeManager.bindProcess(pid: pid)
                let name = wakeManager.processBindings[pid]?.processName ?? "PID \(pid)"
                return .ok(message: "Bound process \(name) (PID: \(pid))")
            } catch {
                return .error(message: error.localizedDescription)
            }

        case .trackProcess(let pid):
            do {
                try wakeManager.trackCaffeinate(pid: pid)
                return .ok(message: "Tracking caffeinate (PID: \(pid))")
            } catch {
                return .error(message: error.localizedDescription)
            }

        case .unbindProcess(let pid):
            wakeManager.unbindProcess(pid: pid)
            return .ok(message: "Unbound PID \(pid)")

        case .status:
            return .status(wakeManager.statusInfo)

        case .stop:
            wakeManager.stopAll()
            return .ok(message: "Stopped all wake sessions")
        }
    }

    private func sendResponseAndClose(response: IPCResponse, clientFd: Int32) {
        serverQueue.async {
            defer { Darwin.close(clientFd) }
            do {
                var responseData = try response.encode()
                responseData.append(UInt8(ascii: "\n"))
                responseData.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else { return }
                    var totalWritten = 0
                    let totalBytes = rawBuffer.count
                    while totalWritten < totalBytes {
                        let written = Darwin.write(clientFd, baseAddress + totalWritten, totalBytes - totalWritten)
                        if written <= 0 {
                            if errno == EAGAIN || errno == EWOULDBLOCK {
                                usleep(1000)
                                continue
                            }
                            break
                        }
                        totalWritten += written
                    }
                }
            } catch {
                Log.ipc.error("Failed to encode/send IPC response: \(error.localizedDescription)")
            }
        }
    }
}
