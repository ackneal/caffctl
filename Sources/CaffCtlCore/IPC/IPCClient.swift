import Foundation
import Darwin
import os

public enum IPCClientError: LocalizedError, Sendable, Equatable {
    case connectionFailed(String)
    case serverNotRunning
    case socketPathTooLong
    case timeout
    case serverClosedConnection
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason):
            return "Failed to connect to CaffCtl socket: \(reason)"
        case .serverNotRunning:
            return "CaffCtl is not running or socket is unavailable."
        case .socketPathTooLong:
            return "UNIX socket path exceeds system maximum length."
        case .timeout:
            return "IPC request timed out."
        case .serverClosedConnection:
            return "Server closed connection unexpectedly without response."
        case .invalidResponse(let reason):
            return "Invalid response from CaffCtl: \(reason)"
        }
    }
}

public struct IPCClient: Sendable {
    public let socketPath: String

    public init(socketPath: String = IPCServer.defaultSocketPath) {
        self.socketPath = socketPath
    }

    public func send(request: IPCRequest, timeout: TimeInterval = 3.0) async throws -> IPCResponse {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try self.sendSync(request: request, timeout: timeout)
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func sendSync(request: IPCRequest, timeout: TimeInterval = 3.0) throws -> IPCResponse {
        var payload = try request.encode()
        payload.append(UInt8(ascii: "\n"))
        let responseData = try sendRaw(data: payload, timeout: timeout)
        do {
            return try IPCResponse.decode(from: responseData)
        } catch {
            throw IPCClientError.invalidResponse(error.localizedDescription)
        }
    }

    public func isServerResponsive(timeout: TimeInterval = 0.15) -> Bool {
        do {
            _ = try sendSync(request: .status, timeout: timeout)
            return true
        } catch {
            return false
        }
    }

    public func sendRaw(data: Data, timeout: TimeInterval = 3.0) throws -> Data {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw IPCClientError.serverNotRunning
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IPCClientError.connectionFailed("Unable to create socket (errno: \(errno))")
        }
        defer { Darwin.close(fd) }

        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout.truncatingRemainder(dividingBy: 1.0)) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let pathCString = socketPath.utf8CString
        let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathCString.count <= sunPathCapacity else {
            throw IPCClientError.socketPathTooLong
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: sunPathCapacity) { dest in
                pathCString.withUnsafeBufferPointer { src in
                    dest.initialize(from: src.baseAddress!, count: src.count)
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, addrLen)
            }
        }

        if connectResult != 0 {
            let err = errno
            if err == ENOENT || err == ECONNREFUSED {
                throw IPCClientError.serverNotRunning
            } else if err == ETIMEDOUT {
                throw IPCClientError.timeout
            } else {
                throw IPCClientError.connectionFailed("connect failed (errno: \(err))")
            }
        }

        // Write all data
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var writtenTotal = 0
            let total = rawBuffer.count
            while writtenTotal < total {
                let written = Darwin.write(fd, base + writtenTotal, total - writtenTotal)
                if written <= 0 {
                    let err = errno
                    if err == EAGAIN || err == EWOULDBLOCK {
                        usleep(1000)
                        continue
                    }
                    if err == ETIMEDOUT {
                        throw IPCClientError.timeout
                    }
                    throw IPCClientError.connectionFailed("write failed (errno: \(err))")
                }
                writtenTotal += written
            }
        }

        // Read response
        var responseBuffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = Darwin.read(fd, &chunk, chunk.count)
            if bytesRead > 0 {
                responseBuffer.append(chunk, count: bytesRead)
                if let newlineIndex = responseBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    return responseBuffer.prefix(upTo: newlineIndex)
                }
            } else if bytesRead == 0 {
                break
            } else {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    usleep(1000)
                    continue
                }
                if err == ETIMEDOUT {
                    throw IPCClientError.timeout
                }
                throw IPCClientError.connectionFailed("read failed (errno: \(err))")
            }
        }

        if responseBuffer.isEmpty {
            throw IPCClientError.serverClosedConnection
        }

        return responseBuffer
    }
}
