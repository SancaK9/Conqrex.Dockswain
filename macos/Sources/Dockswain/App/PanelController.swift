import SwiftUI
import AppKit

/// A floating panel that hosts the SwiftUI UI. Unlike a MenuBarExtra window it can
/// be dragged anywhere and snapped to the left/right screen edge (sidebar style) or
/// reset to a free-floating popup. Its frame is remembered between launches.
@MainActor
final class PanelController: ObservableObject {
    /// Panel must become key so text fields (server form, password) accept input.
    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    enum Dock: String { case floating, left, right }

    @Published private(set) var dock: Dock =
        Dock(rawValue: UserDefaults.standard.string(forKey: "panelDock") ?? "") ?? .floating

    private let panel: KeyablePanel
    private weak var statusItem: NSStatusItem?
    private let defaultSize = NSSize(width: 380, height: 540)

    init(state: AppState) {
        panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true      // drag from any empty area
        panel.level = .floating
        panel.hidesOnDeactivate = false               // stay put when docked to a side
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 320, height: 320)

        // Inject self so the SwiftUI footer can call the dock actions.
        let root = MenuContentView()
            .environmentObject(state)
            .environmentObject(self)
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        panel.setFrameAutosaveName("DockswainPanel")
    }

    func attach(to item: NSStatusItem) { statusItem = item }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            applyDock(dock, animate: false)
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Dock / position

    func setDock(_ d: Dock) {
        dock = d
        UserDefaults.standard.set(d.rawValue, forKey: "panelDock")
        applyDock(d, animate: true)
    }

    private func applyDock(_ d: Dock, animate: Bool) {
        guard let screen = currentScreen() else { return }
        let vf = screen.visibleFrame
        let w = defaultSize.width
        switch d {
        case .left:
            panel.setFrame(NSRect(x: vf.minX, y: vf.minY, width: w, height: vf.height),
                           display: true, animate: animate)
        case .right:
            panel.setFrame(NSRect(x: vf.maxX - w, y: vf.minY, width: w, height: vf.height),
                           display: true, animate: animate)
        case .floating:
            // restore the autosaved/free frame; if it's off-screen, anchor near the icon
            if !screen.visibleFrame.intersects(panel.frame) || panel.frame.size.height >= vf.height - 4 {
                positionNearStatusItem()
            }
        }
    }

    private func positionNearStatusItem() {
        var frame = NSRect(origin: .zero, size: defaultSize)
        if let button = statusItem?.button, let win = button.window {
            let b = win.convertToScreen(button.frame)
            let vf = (win.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            var x = b.midX - frame.width / 2
            x = min(max(vf.minX + 8, x), vf.maxX - frame.width - 8)
            let y = b.minY - frame.height - 6
            frame.origin = NSPoint(x: x, y: y)
        }
        panel.setFrame(frame, display: true, animate: true)
    }

    private func currentScreen() -> NSScreen? {
        panel.screen
            ?? statusItem?.button?.window?.screen
            ?? NSScreen.main
    }
}
