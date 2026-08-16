import Foundation

public struct GlobalStatusInfo: Codable, Sendable, Equatable {
    public let duration: TimeInterval?
    public let startDate: Date
    public let expiryDate: Date?
    public let remainingSeconds: TimeInterval?

    public init(duration: TimeInterval?, startDate: Date, expiryDate: Date?, remainingSeconds: TimeInterval?) {
        self.duration = duration
        self.startDate = startDate
        self.expiryDate = expiryDate
        self.remainingSeconds = remainingSeconds
    }
}

public struct ProcessStatusInfo: Codable, Sendable, Equatable {
    public let pid: pid_t
    public let name: String
    public let startDate: Date
    public let elapsedSeconds: TimeInterval

    public init(pid: pid_t, name: String, startDate: Date = Date(), elapsedSeconds: TimeInterval = 0) {
        self.pid = pid
        self.name = name
        self.startDate = startDate
        self.elapsedSeconds = elapsedSeconds
    }
}

public struct StatusPayload: Codable, Sendable, Equatable {
    public let isActive: Bool
    public let global: GlobalStatusInfo?
    public let processes: [ProcessStatusInfo]
    public let caffeinateRunning: Bool
    public let lastError: String?

    public init(
        isActive: Bool,
        global: GlobalStatusInfo?,
        processes: [ProcessStatusInfo],
        caffeinateRunning: Bool,
        lastError: String?
    ) {
        self.isActive = isActive
        self.global = global
        self.processes = processes
        self.caffeinateRunning = caffeinateRunning
        self.lastError = lastError
    }
}

public enum IPCRequest: Codable, Sendable, Equatable {
    case activateGlobal(duration: TimeInterval?, clientPID: pid_t? = nil)
    case deactivateGlobal
    case bindProcess(pid: pid_t)
    case unbindProcess(pid: pid_t)
    case status
    case stop

    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> IPCRequest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(IPCRequest.self, from: data)
    }
}

public enum IPCResponse: Codable, Sendable, Equatable {
    case status(StatusPayload)
    case ok(message: String)
    case error(message: String)

    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> IPCResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(IPCResponse.self, from: data)
    }
}
