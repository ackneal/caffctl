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
final class StatusItemPopoverController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var isMenuOpen = false
    private let appState: AppState
    private let navState = MenuBarNavigationState()
    private var cancellables = Set<AnyCancellable>()

    init(appState: AppState) {
        self.appState = appState
        super.init()

        let hostingView = NSHostingView(rootView: MenuBarView(wakeManager: appState.wakeManager, navState: navState))
        hostingView.frame.size = hostingView.fittingSize

        let menuItem = NSMenuItem()
        menuItem.view = hostingView

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(menuItem)
        self.menu = menu

        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.menu = menu

        // Observe WakeManager changes
        appState.wakeManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusItemTitleIfNeeded()
                }
            }
            .store(in: &cancellables)

        updateStatusItemTitleNow()

        // Refresh title every second only when the menu is closed to avoid anchor movement
        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateStatusItemTitleIfNeeded()
            }
            .store(in: &cancellables)
    }

    private func updateStatusItemTitleIfNeeded() {
        guard !isMenuOpen else { return }
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

    func menuWillOpen(_ menu: NSMenu) {
        navState.resetToMain()
        navState.isPopoverPresented = true
        isMenuOpen = true
        updateStatusItemTitleNow()
    }

    func menuDidClose(_ menu: NSMenu) {
        navState.isPopoverPresented = false
        navState.resetToMain()
        isMenuOpen = false
        updateStatusItemTitleNow()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState?
    private var statusItemController: StatusItemPopoverController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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
