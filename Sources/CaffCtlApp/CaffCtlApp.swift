import SwiftUI
import AppKit
import Combine
import CaffCtlCore

@MainActor
final class AppState: ObservableObject {
    let wakeManager: WakeManager
    let ipcServer: IPCServer

    init() {
        let manager = WakeManager()
        let server = IPCServer(wakeManager: manager)
        self.wakeManager = manager
        self.ipcServer = server

        do {
            try server.start()
            Log.app.info("IPC Server started on app launch")
        } catch {
            Log.app.error("Failed to start IPC server on launch: \(error.localizedDescription)")
        }

    }

    func cleanup() {
        ipcServer.stop()
        wakeManager.cleanup()
        Log.app.info("App cleanup finished")
    }
}

@MainActor
final class StatusItemPopoverController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let appState: AppState
    private let navState = MenuBarNavigationState()
    private var cancellables = Set<AnyCancellable>()

    init(appState: AppState) {
        self.appState = appState
        super.init()

        // 1. Configure NSPopover with constant fixed size and animates = false
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 250, height: 178)
        let hostingController = NSHostingController(rootView: MenuBarView(wakeManager: appState.wakeManager, navState: navState))
        // Popover height auto-fits the SwiftUI content — no dead space below Quit.
        hostingController.sizingOptions = .preferredContentSize
        popover.contentViewController = hostingController
        popover.delegate = self
        self.popover = popover

        // 2. Configure NSStatusItem
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = self.statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        // 3. Observe WakeManager changes
        appState.wakeManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusItemTitleIfNeeded()
                }
            }
            .store(in: &cancellables)

        updateStatusItemTitleNow()

        // Refresh title every second only when popover is closed to avoid anchor movement
        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateStatusItemTitleIfNeeded()
            }
            .store(in: &cancellables)
    }

    private func updateStatusItemTitleIfNeeded() {
        // Do NOT resize status item button while popover is open to prevent macOS popover re-anchor jumps!
        guard !popover.isShown else { return }
        updateStatusItemTitleNow()
    }

    private func updateStatusItemTitleNow() {
        guard let button = statusItem.button else { return }
        let isActive = appState.wakeManager.isActive
        let symbolName = isActive ? "cup.and.saucer.fill" : "cup.and.saucer"
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "CaffCtl")?.withSymbolConfiguration(config) {
            image.isTemplate = true
            button.image = image
        }
        button.title = ""
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // ALWAYS reset to main screen before opening!
            navState.resetToMain()
            navState.isPopoverPresented = true
            updateStatusItemTitleNow()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        // ALWAYS reset to main screen on close!
        navState.isPopoverPresented = false
        navState.resetToMain()
        updateStatusItemTitleNow()
    }
}

enum CLIInstaller {
    static func installSymlinksIfNeeded() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let localBin = home.appendingPathComponent(".local/bin")

        // 1. Locate the embedded or sibling caffctl binary
        let bundleURL = Bundle.main.bundleURL
        var cliURL: URL? = nil

        let appCliPath = bundleURL.appendingPathComponent("Contents/MacOS/caffctl")
        if fm.isExecutableFile(atPath: appCliPath.path) {
            cliURL = appCliPath
        } else {
            let siblingCli = bundleURL.deletingLastPathComponent().appendingPathComponent("caffctl")
            if fm.isExecutableFile(atPath: siblingCli.path) {
                cliURL = siblingCli
            }
        }

        guard let sourceCLI = cliURL else { return }

        // 2. Ensure ~/.local/bin exists
        try? fm.createDirectory(at: localBin, withIntermediateDirectories: true)

        // 3. Create or update symlink for caffeinate ONLY
        let caffeinateTarget = localBin.appendingPathComponent("caffeinate")
        updateSymlink(at: caffeinateTarget, pointingTo: sourceCLI.path)

        Log.app.info("caffeinate symlink verified in \(localBin.path)")
    }

    private static func updateSymlink(at targetURL: URL, pointingTo destinationPath: String) {
        let fm = FileManager.default
        if let currentDest = try? fm.destinationOfSymbolicLink(atPath: targetURL.path), currentDest == destinationPath {
            return
        }
        try? fm.removeItem(at: targetURL)
        try? fm.createSymbolicLink(atPath: targetURL.path, withDestinationPath: destinationPath)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState?
    private var statusItemController: StatusItemPopoverController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        CLIInstaller.installSymlinksIfNeeded()
        let state = AppState()
        self.appState = state
        self.statusItemController = StatusItemPopoverController(appState: state)
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.cleanup()
    }
}

@main
struct CaffCtlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
