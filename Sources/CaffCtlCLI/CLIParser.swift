import Foundation

public enum DurationParser {
    public static func parse(_ str: String) -> TimeInterval? {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let direct = Double(trimmed) {
            return direct > 0 ? direct : nil
        }

        var totalSeconds: Double = 0
        var currentNumber = ""
        var matched = false

        for char in trimmed {
            if char.isNumber || char == "." {
                currentNumber.append(char)
            } else if char == "h" {
                guard let val = Double(currentNumber), val > 0 else { return nil }
                totalSeconds += val * 3600
                currentNumber = ""
                matched = true
            } else if char == "m" {
                guard let val = Double(currentNumber), val > 0 else { return nil }
                totalSeconds += val * 60
                currentNumber = ""
                matched = true
            } else if char == "s" {
                guard let val = Double(currentNumber), val > 0 else { return nil }
                totalSeconds += val
                currentNumber = ""
                matched = true
            } else {
                return nil
            }
        }

        if !currentNumber.isEmpty {
            return nil
        }

        return matched && totalSeconds > 0 ? totalSeconds : nil
    }
}
