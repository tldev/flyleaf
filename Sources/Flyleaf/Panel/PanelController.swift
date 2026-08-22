import AppKit
import SwiftUI

// Floating, non-activating, always-on-top. The panel never takes focus from
// whatever the reader has in front; optional click-through makes it inert.
@MainActor
final class PanelController {
    static let shared = PanelController()

    private var panel: NSPanel?
    private weak var state: AppState?

    func configure(state: AppState) {
        self.state = state
    }

    func show() {
        guard let state else { return }
        if panel == nil {
            let hosting = NSHostingController(rootView: PanelRootView().environment(state))
            hosting.sizingOptions = []

            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            p.contentViewController = hosting
            // Assigning contentViewController collapses the frame to the
            // hosting view's initial (zero) size; a zero window never lays
            // out SwiftUI, so the real size preference would never arrive.
            p.setContentSize(NSSize(width: 400, height: 420))
            p.isFloatingPanel = true
            p.level = .floating
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = true
            p.isMovableByWindowBackground = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.animationBehavior = .utilityWindow
            panel = p
            positionInitially(p)
        }
        applyPrefs()
        panel?.orderFrontRegardless()
        Prefs.shared.panelVisible = true
        if let p = panel {
            log(.panel, "Panel shown at \(NSStringFromRect(p.frame)) visible=\(p.isVisible) screen=\(p.screen?.frame.debugDescription ?? "none")")
        }
    }

    func hide() {
        panel?.orderOut(nil)
        Prefs.shared.panelVisible = false
        log(.panel, "Panel hidden")
    }

    func toggle() {
        if panel?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func applyPrefs() {
        panel?.ignoresMouseEvents = Prefs.shared.clickThrough
    }

    // The SwiftUI content reports its ideal size through a preference key and
    // the panel is resized here, outside the layout pass. Letting AppKit
    // derive the size from constraints (sizingOptions) recurses fatally in a
    // borderless panel whose content re-lays-out on frame changes.
    private var pendingResize = false

    func setContentSize(_ size: CGSize) {
        guard size.width > 10, size.height > 10 else { return }
        let target = NSSize(width: ceil(size.width), height: ceil(size.height))
        guard !pendingResize else { return }
        pendingResize = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingResize = false
            guard let panel = self.panel else { return }
            let current = panel.contentView?.frame.size ?? .zero
            guard abs(current.width - target.width) > 1 || abs(current.height - target.height) > 1 else { return }
            let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
            panel.setContentSize(target)
            panel.setFrameTopLeftPoint(topLeft)
            if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
                var frame = panel.frame
                if frame.minY < visible.minY { frame.origin.y = visible.minY }
                if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
                if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
                if frame.minX < visible.minX { frame.origin.x = visible.minX }
                if frame.origin != panel.frame.origin { panel.setFrameOrigin(frame.origin) }
            }
            log(.panel, .debug, "Panel resized to \(NSStringFromRect(panel.frame))")
        }
    }

    private func positionInitially(_ p: NSPanel) {
        let key = "FlyleafPanelFrame"
        if let saved = UserDefaults.standard.string(forKey: key) {
            let frame = NSRectFromString(saved)
            if frame.width > 50 {
                p.setFrameOrigin(frame.origin)
                observeMoves(p, key: key)
                return
            }
        }
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            p.setFrameTopLeftPoint(NSPoint(
                x: visible.maxX - p.frame.width - 28,
                y: visible.maxY - 28
            ))
        }
        observeMoves(p, key: key)
    }

    private func observeMoves(_ p: NSPanel, key: String) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: p,
            queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            let frameString = NSStringFromRect(window.frame)
            DispatchQueue.main.async {
                UserDefaults.standard.set(frameString, forKey: key)
            }
        }
    }
}
