import SwiftUI
import AppKit
import QuartzCore

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

    /// When true the panel stays open after it loses focus; when false a click
    /// outside (deactivating the app) closes it, like a normal menu-bar popup.
    @Published private(set) var pinnedOpen: Bool = UserDefaults.standard.bool(forKey: "panelPinned")

    private let panel: KeyablePanel
    private weak var statusItem: NSStatusItem?
    private var clickMonitor: Any?
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
        // Never auto-hide on app deactivation: an accessory app isn't reliably
        // "active", which would hide the panel the instant it's shown. Closing on a
        // click outside is handled by a global mouse monitor instead (see below).
        panel.hidesOnDeactivate = false
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
        installClickOutsideMonitor()
    }

    /// A global mouse-down monitor fires only for clicks in OTHER apps / the desktop
    /// (never our own panel or status item, which are local events). So when the
    /// panel isn't pinned, any click outside it closes it — without tying that to the
    /// unreliable app-active state.
    private func installClickOutsideMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.panel.isVisible && !self.pinnedOpen { self.hideAnimated() }
            }
        }
    }

    func attach(to item: NSStatusItem) { statusItem = item }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible { hideAnimated() } else { showAnimated() }
    }

    // MARK: - Open/close animation (a genie-style pop from the menu-bar edge)

    private var animating = false

    /// Show: start small + transparent, anchored at the top (toward the menu bar),
    /// then scale+fade up to the real frame with an ease-out curve.
    private func showAnimated() {
        guard !animating else { return }
        applyDock(dock, animate: false)
        let target = panel.frame
        panel.setFrame(shrunk(target), display: false)
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        animating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.20
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in self?.animating = false })
    }

    /// Hide: scale+fade back down toward the top, then order out and restore the
    /// real frame so the next open starts from the right place.
    private func hideAnimated() {
        guard !animating, panel.isVisible else { return }
        let target = panel.frame
        animating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(shrunk(target), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.panel.setFrame(target, display: false)
            self.panel.alphaValue = 1
            self.animating = false
        })
    }

    /// Frame shrunk toward its top edge, for the "pop from the menu bar" feel.
    private func shrunk(_ r: NSRect) -> NSRect {
        let w = r.width * 0.86
        let h = r.height * 0.55
        return NSRect(x: r.midX - w / 2, y: r.maxY - h, width: w, height: h)
    }

    // MARK: - Pin (stay open when clicking away)

    func togglePin() {
        pinnedOpen.toggle()
        UserDefaults.standard.set(pinnedOpen, forKey: "panelPinned")
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
