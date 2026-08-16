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

    private func formatRemainingText(_ seconds: TimeInterval) -> String {
        formatTimeText(seconds, suffix: "left", roundUp: true)
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
        .padding(.vertical, 12)
        .frame(width: 250, height: 180)
        .onReceive(timer) { newDate in
            self.now = newDate
        }
    }

    // MARK: - Main Screen View
    private var mainScreenView: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 1. Header (Overall Status)
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(wakeManager.isActive ? Color.orange : Color.gray.opacity(0.2))
                        .frame(width: 24, height: 24)
                    Image(systemName: wakeManager.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(wakeManager.isActive ? .white : .secondary)
                }

                Text("CaffCtl")
                    .font(.system(size: 13, weight: .bold))

                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(wakeManager.isActive ? Color.green : Color.gray.opacity(0.6))
                        .frame(width: 6, height: 6)
                    Text(wakeManager.isActive ? "Active" : "Inactive")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(wakeManager.isActive ? .primary : .secondary)
                }
            }

            Divider()

            // 2. Global Session Row
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("GLOBAL")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)

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

                // Clickable Duration / Status Row
                Button {
                    navState.currentScreen = .durationSelection
                } label: {
                    HStack(alignment: .center) {
                        if let global = wakeManager.globalSession, !global.isExpired {
                            if let remaining = global.remainingSeconds {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(formatRemainingText(remaining))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.primary)
                                    Text(formatElapsedText(now.timeIntervalSince(global.startDate)))
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                Text(formatElapsedText(now.timeIntervalSince(global.startDate)))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.primary)
                            }
                        } else {
                            Text("Set duration")
                                .font(.system(size: 12))
                                .foregroundColor(.primary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                    .contentShape(Rectangle())
                    .frame(height: 26)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // 3. Sessions Row
            Button {
                navState.currentScreen = .sessionsList
            } label: {
                HStack(spacing: 6) {
                    Text("Sessions")
                        .font(.system(size: 12))
                        .foregroundColor(.primary)

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
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .contentShape(Rectangle())
                .frame(height: 22)
            }
            .buttonStyle(.plain)

            Divider()

            // 4. Footer
            HStack {
                Spacer()

                Button {
                    wakeManager.cleanup()
                    NSApplication.shared.terminate(nil)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                        Text("Quit")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q")
            }
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

