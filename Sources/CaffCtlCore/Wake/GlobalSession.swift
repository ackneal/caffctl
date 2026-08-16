import Foundation

public struct GlobalSession: Sendable, Equatable {
    public let duration: TimeInterval?
    public let startDate: Date
    public let expiryDate: Date?

    public init(duration: TimeInterval?, startDate: Date = Date()) {
        self.duration = duration
        self.startDate = startDate
        if let duration = duration {
            self.expiryDate = startDate.addingTimeInterval(duration)
        } else {
            self.expiryDate = nil
        }
    }

    public var isExpired: Bool {
        guard let expiryDate = expiryDate else { return false }
        return Date() >= expiryDate
    }

    public var remainingSeconds: TimeInterval? {
        guard let expiryDate = expiryDate else { return nil }
        return max(0, expiryDate.timeIntervalSince(Date()))
    }

    public var elapsedSeconds: TimeInterval {
        max(0, Date().timeIntervalSince(startDate))
    }
}
