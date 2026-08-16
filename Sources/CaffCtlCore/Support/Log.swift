import Foundation
import os

public enum Log {
    public static let subsystem = "com.caffctl.app"

    public static let wake = Logger(subsystem: subsystem, category: "wake")
    public static let ipc = Logger(subsystem: subsystem, category: "ipc")
    public static let process = Logger(subsystem: subsystem, category: "process")
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let cli = Logger(subsystem: subsystem, category: "cli")
}
