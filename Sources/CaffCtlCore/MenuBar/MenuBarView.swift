import SwiftUI
import AppKit

public enum MenuBarScreen: Sendable {
    case main
    case durationSelection
    case sessionsList
}

@MainActor
public final class MenuBarNavigationState: ObservableObject {
    @Published public var currentScreen: MenuBarScreen = .main
    @Published public var showingCustomInput: Bool = false

    public init() {}

    public func resetToMain() {
        self.currentScreen = .main
        self.showingCustomInput = false
    }
}

public struct MenuBarView: View {
    @ObservedObject public var wakeManager: WakeManager
    @ObservedObject public var navState: MenuBarNavigationState
    @State private var now = Date()
    @State private var customMinutesString = ""
    @State private var copiedPID: pid_t? = nil
    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    public init(wakeManager: WakeManager, navState: MenuBarNavigationState? = nil) {
        self.wakeManager = wakeManager
        self.navState = navState ?? MenuBarNavigationState()
    }

    private func formatTimeText(_ seconds: TimeInterval, suffix: String, roundUp: Bool = false) -> String {
        let totalSec = max(0, roundUp ? Int(ceil(seconds)) : Int(seconds))
        if totalSec < 60 { return "\(totalSec)s \(suffix)" }
        let mins = totalSec / 60
        if mins < 60 { return "\(mins)m \(suffix)" }
        let hours = mins / 60
        let remainMins = mins % 60
        if remainMins == 0 { return "\(hours)h \(suffix)" }
        return "\(hours)h \(String(format: "%02d", remainMins))m \(suffix)"
    }

    private func formatElapsedText(_ seconds: TimeInterval) -> String {
        formatTimeText(seconds, suffix: "elapsed")
    }

    private func formatClock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    private var globalSessionTimeText: String {
        guard let global = wakeManager.globalSession, !global.isExpired else { return "" }
        if let remaining = global.remainingSeconds {
            return formatClock(remaining) + " left"
        }
        return formatClock(now.timeIntervalSince(global.startDate))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch navState.currentScreen {
            case .main:
                mainScreenView
            case .durationSelection:
                durationSelectionView
            case .sessionsList:
                sessionsListView
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(width: 250)
        .onReceive(timer) { newDate in
            self.now = newDate
        }
    }

    // MARK: - Main Screen View
    private var mainScreenView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. Title + toggle (bold)
            HStack(spacing: 8) {
                Text("CaffCtl")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)

                Spacer()

                Toggle("", isOn: Binding<Bool>(
                    get: {
                        wakeManager.globalSession != nil && !wakeManager.globalSession!.isExpired
                    },
                    set: { isTurnedOn in
                        if isTurnedOn {
                            wakeManager.activateGlobal(duration: nil)
                        } else {
                            wakeManager.deactivateGlobal()
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
            .padding(.bottom, 10)

            Divider()

            // 2. caffeinate + numeric session time
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("caffeinate")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Spacer()

                    Text(globalSessionTimeText)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 7)

                // 3. Set Duration
                Button {
                    navState.currentScreen = .durationSelection
                } label: {
                    HStack(spacing: 6) {
                        Text("Set Duration")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 7)
            }

            Divider()

            // 4. Other Sessions (gray header, like "Other Networks")
            Button {
                navState.currentScreen = .sessionsList
            } label: {
                HStack(spacing: 6) {
                    Text("Other Sessions")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Spacer()

                    if !wakeManager.processBindings.isEmpty {
                        Text("\(wakeManager.processBindings.count)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.secondary.opacity(0.18))
                            .clipShape(Capsule())
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 7)

            Divider()

            // 5. Quit (tight footer)
            HStack {
                Spacer()

                Button {
                    wakeManager.cleanup()
                    NSApplication.shared.terminate(nil)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                            .font(.system(size: 10, weight: .medium))
                        Text("Quit")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q")
            }
            .padding(.vertical, 7)
        }
    }

    // MARK: - Duration Selection View
    private var durationSelectionView: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header with Back button and top-aligned Clear button
            HStack {
                Button {
                    navState.resetToMain()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                        Text("Set duration")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(.primary)
                }
                .buttonStyle(.plain)

                Spacer()

                if wakeManager.globalSession != nil && !wakeManager.globalSession!.isExpired {
                    Button {
                        wakeManager.deactivateGlobal()
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                            Text("Clear")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 20)

            Divider()

            let durations: [(String, TimeInterval)] = [
                ("30 minutes", 30 * 60),
                ("1 hour", 60 * 60),
                ("2 hours", 2 * 60 * 60),
                ("4 hours", 4 * 60 * 60)
            ]

            VStack(spacing: 2) {
                ForEach(durations, id: \.1) { item in
                    let isChecked = wakeManager.globalSession != nil && !wakeManager.globalSession!.isExpired && wakeManager.globalSession?.duration == item.1
                    durationRow(title: item.0, duration: item.1, isChecked: isChecked)
                }
            }

            Divider()

            if navState.showingCustomInput {
                HStack(spacing: 5) {
                    TextField("Minutes", text: $customMinutesString)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.mini)
                    Button("Set") {
                        if let mins = Double(customMinutesString), mins > 0 {
                            wakeManager.activateGlobal(duration: mins * 60)
                            navState.showingCustomInput = false
                        }
                    }
                    .controlSize(.mini)

                    Button {
                        navState.showingCustomInput = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 20)
            } else {
                Button {
                    navState.showingCustomInput = true
                } label: {
                    HStack {
                        Text("Custom…")
                            .font(.system(size: 12))
                            .foregroundColor(.primary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .frame(height: 20)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func durationRow(title: String, duration: TimeInterval, isChecked: Bool) -> some View {
        Button {
            if isChecked {
                wakeManager.deactivateGlobal()
            } else {
                wakeManager.activateGlobal(duration: duration)
            }
        } label: {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)

                Spacer()

                if isChecked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle())
            .frame(height: 20)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sessions List View
    private var sessionsListView: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header / Back button
            Button {
                navState.resetToMain()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                    Text("Sessions")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundColor(.primary)
            }
            .buttonStyle(.plain)
            .frame(height: 20)

            Divider()

            if wakeManager.processBindings.isEmpty {
                VStack(alignment: .center, spacing: 4) {
                    Spacer()
                    Text("No active sessions")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(wakeManager.processBindings.values.sorted { $0.pid < $1.pid }), id: \.pid) { binding in
                            let elapsed = now.timeIntervalSince(binding.startDate)
                            HStack(spacing: 8) {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("\(binding.pid)", forType: .string)
                                    copiedPID = binding.pid
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                        if copiedPID == binding.pid {
                                            copiedPID = nil
                                        }
                                    }
                                } label: {
                                    ZStack {
                                        if copiedPID == binding.pid {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 14, weight: .bold))
                                                .foregroundColor(.green)
                                                .frame(width: 20, height: 20)
                                        } else if let icon = binding.appIcon {
                                            Image(nsImage: icon)
                                                .resizable()
                                                .aspectRatio(contentMode: .fit)
                                                .frame(width: 20, height: 20)
                                        } else {
                                            Image(systemName: "terminal.fill")
                                                .font(.system(size: 12))
                                                .foregroundColor(.accentColor)
                                                .frame(width: 20, height: 20)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .help(copiedPID == binding.pid ? "Copied PID: \(binding.pid)!" : "Click to copy PID: \(binding.pid)")

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(binding.processName)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Text(formatElapsedText(elapsed))
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Button("Release") {
                                    wakeManager.unbindProcess(pid: binding.pid)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                            .help(binding.commandLine)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
    }
}

