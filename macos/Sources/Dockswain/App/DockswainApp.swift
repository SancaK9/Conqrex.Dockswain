import SwiftUI
import AppKit
import Combine

@main
struct DockswainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The real UI is a draggable NSPanel owned by the AppDelegate. This empty
        // Settings scene just satisfies the App protocol; it's never shown (the app
        // is an accessory with no menu).
        Settings { EmptyView() }
    }
}

/// Owns the menu bar status item and the floating panel. Replaces MenuBarExtra so
/// the panel can be moved and docked to either screen edge.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private var panel: PanelController!
    private var statusItem: NSStatusItem!
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)        // menu-bar only, no Dock icon

        panel = PanelController(state: state)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⚓"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        panel.attach(to: statusItem)

        // Keep the menu bar badge (running/total) in sync with the container list.
        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateBadge() }
            .store(in: &cancellables)
        updateBadge()
    }

    @objc private func togglePanel() { panel.toggle() }

    private func updateBadge() {
        let badge = state.badge
        statusItem.button?.title = badge.isEmpty ? "⚓" : "⚓ \(badge)"
    }
}
