import AppKit
import SwiftUI

class MouseTrackingView: NSView {
    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onMouseDown?() }

    // Accept the click without activating the app
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// One single panel = the whole notch widget. Click it → the whole thing expands.
class OverlayPanel: NSPanel {
    let state: PillState

    private var compactRect:  NSRect = .zero
    private var hoverRect:    NSRect = .zero   // slightly larger compact frame, shown on hover
    private var expandedRect: NSRect = .zero
    private var notchWidth:   CGFloat = 0
    private var topInset:     CGFloat = 0   // notch / menu-bar height the content must clear
    private var globalMonitor: Any?
    private var isHovering = false

    init(sharedState: PillState) {
        self.state = sharedState

        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed        = false
        // Float above *all* ordinary app windows (and the menu bar). We deliberately
        // do NOT join fullscreen spaces — instead we hide while a fullscreen app is
        // front (see updateFullscreenVisibility), so the island never covers fullscreen video.
        level                       = .screenSaver
        backgroundColor             = .clear
        isOpaque                    = false
        hasShadow                   = false
        collectionBehavior          = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isMovableByWindowBackground = false

        state.onExpandRequest = { [weak self] expand in self?.setExpanded(expand) }
        state.onHoverRequest  = { [weak self] hover  in self?.setHovered(hover) }

        computeFrames()
        setFrame(state.isExpanded ? expandedRect : compactRect, display: false)

        let tracker = MouseTrackingView(frame: NSRect(origin: .zero, size: frame.size))
        tracker.autoresizingMask = [.width, .height]
        tracker.wantsLayer = true
        tracker.layer?.backgroundColor = CGColor.clear
        tracker.onMouseDown = { [weak self] in self?.toggleExpanded() }

        let hosting = NSHostingView(rootView:
            AnyView(NotchView(notchWidth: notchWidth, topInset: topInset).environmentObject(state))
        )
        hosting.frame = tracker.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = CGColor.clear

        tracker.addSubview(hosting)
        contentView = tracker

        // Collapse when the user clicks anywhere outside the widget
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self, self.state.isExpanded else { return }
            DispatchQueue.main.async { self.setExpanded(false) }
        }

        // Hide while any app is in fullscreen on the active space; reappear otherwise.
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(updateFullscreenVisibility),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        updateFullscreenVisibility()
    }

    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // A fullscreen window auto-hides the menu bar, collapsing the top inset to ~0.
    // Use that as the signal to get out of the way; otherwise float on top.
    @objc private func updateFullscreenVisibility() {
        let screen = notchScreen ?? NSScreen.main
        let menuBarGap = screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 1
        if menuBarGap < 1 {
            orderOut(nil)
        } else if !isVisible {
            setFrame(state.isExpanded ? expandedRect : compactRect, display: false)
            orderFront(nil)
        }
    }

    // The built-in (notch) display when present, so the island always lands there.
    private var notchScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    // MARK: Frame computation → returns the physical notch width (0 if none)

    private func computeFrames() {
        guard let screen = notchScreen else { return }

        let eW: CGFloat = 380

        if let lArea = screen.auxiliaryTopLeftArea,
           let rArea = screen.auxiliaryTopRightArea {
            // Notch Mac: one bar straddling the notch (art left, waveform right, notch black in the middle).
            notchWidth = max(0, rArea.minX - lArea.maxX)
            topInset   = lArea.height
            let sideExtra: CGFloat = 62
            let cW = notchWidth + sideExtra * 2
            let cH = lArea.height
            let cx = (lArea.maxX + rArea.minX) / 2   // notch centre
            let eH = topInset + 34 + 24 + 188          // notch strip + navbar + gap + tab content

            compactRect = NSRect(x: cx - cW / 2, y: lArea.minY, width: cW, height: cH)
            hoverRect = inflatedCompact(compactRect, dw: 20, dh: 6)
            // Top edge stays pinned to the bezel — the card grows straight DOWN, no shift, no gap above.
            expandedRect = NSRect(x: cx - eW / 2, y: compactRect.maxY - eH, width: eW, height: eH)
        } else {
            // Non-notch Mac: one small pill centred at the top; expands into the same card.
            let menuBarH = screen.frame.height - screen.visibleFrame.height - screen.visibleFrame.origin.y
            notchWidth = 0
            topInset   = menuBarH
            let cW: CGFloat = 120
            let cH = menuBarH
            let cx = screen.frame.midX
            let eH = topInset + 164

            compactRect = NSRect(x: cx - cW / 2, y: screen.frame.maxY - cH, width: cW, height: cH)
            hoverRect = inflatedCompact(compactRect, dw: 16, dh: 4)
            expandedRect = NSRect(x: cx - eW / 2, y: compactRect.maxY - eH, width: eW, height: eH)
        }
    }

    // Grow sideways + downward while keeping the top edge pinned to the bezel.
    private func inflatedCompact(_ rect: NSRect, dw: CGFloat, dh: CGFloat) -> NSRect {
        NSRect(x: rect.midX - (rect.width + dw) / 2,
               y: rect.maxY - (rect.height + dh),
               width: rect.width + dw,
               height: rect.height + dh)
    }

    // MARK: Expand / collapse — the whole widget morphs as one

    func toggleExpanded() { setExpanded(!state.isExpanded) }

    func setExpanded(_ expanded: Bool) {
        state.isExpanded = expanded
        // When collapsing while the cursor is still over the pill, settle into the
        // enlarged hover frame rather than snapping all the way down.
        let target = expanded ? expandedRect : (isHovering ? hoverRect : compactRect)
        NSAnimationContext.runAnimationGroup { ctx in
            // Match SwiftUI's .easeOut(duration: 0.4) so the frame and the content grow in lockstep.
            ctx.duration = 0.4
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(target, display: true)
        }
        // Become key while expanded so ⌘-arrow keyboard navigation works; resign on collapse.
        if expanded { makeKey() } else { resignKey() }
    }

    // Hover grow/shrink of the whole compact pill (ignored while expanded).
    func setHovered(_ hovered: Bool) {
        isHovering = hovered
        guard !state.isExpanded else { return }
        let target = hovered ? hoverRect : compactRect
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(target, display: true)
        }
    }

    // Only key while expanded — keeps the compact pill non-interactive with the keyboard,
    // but lets the expanded card receive ⌘-arrow navigation.
    override var canBecomeKey: Bool  { state.isExpanded }
    override var canBecomeMain: Bool { false }

    // MARK: Keyboard navigation (only while expanded)
    //  ⌘← / ⌘→  cycle tabs   ·   ⌘↓ / esc  collapse
    override func keyDown(with event: NSEvent) {
        guard state.isExpanded else { super.keyDown(with: event); return }
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53:                       setExpanded(false)     // esc
        case 123 where cmd:            state.cycleTab(-1)     // ⌘←
        case 124 where cmd:            state.cycleTab(1)      // ⌘→
        case 125 where cmd:            setExpanded(false)     // ⌘↓
        default:                       super.keyDown(with: event)
        }
    }
}
