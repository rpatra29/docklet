import AppKit
import SwiftUI
import UniformTypeIdentifiers

// File types a Finder drag may advertise. Register for all of them so
// `draggingEntered` actually fires regardless of which Finder exposes.
let dropTypes: [NSPasteboard.PasteboardType] = [
    .fileURL,
    NSPasteboard.PasteboardType("public.file-url"),
    NSPasteboard.PasteboardType("NSFilenamesPboardType")
]

// Pulls file URLs out of a drag, tolerating both modern and legacy encodings.
func droppedFileURLs(_ sender: NSDraggingInfo) -> [URL] {
    let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL],
       !urls.isEmpty {
        return urls
    }
    if let paths = sender.draggingPasteboard.propertyList(forType:
        NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
        return paths.map { URL(fileURLWithPath: $0) }
    }
    return []
}

// Shared drag-destination callbacks, mixed into both the tracker and the hosting view
// (whichever AppKit picks as the destination, the behaviour is identical).
final class DragCallbacks {
    var onDragEntered: (() -> Void)?
    var onDragExited:  (() -> Void)?
    var onFilesDropped: (([URL]) -> Void)?
}

class MouseTrackingView: NSView {
    var onMouseDown: (() -> Void)?
    let drag = DragCallbacks()

    override func mouseDown(with event: NSEvent) { onMouseDown?() }

    // Accept the click without activating the app
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        drag.onDragEntered?(); return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { drag.onDragExited?() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFileURLs(sender)
        guard !urls.isEmpty else { return false }
        drag.onFilesDropped?(urls); return true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { drag.onDragExited?() }
}

// Lets SwiftUI controls (e.g. the compact pill's play/skip buttons) register on the
// very first click even though the collapsed panel never becomes key. Also the frontmost
// view, so it's the one AppKit hands file drags to — handled here, not via SwiftUI .onDrop,
// so the collapsed pill is a reliable drop target and we control focus (expanding for a drag
// must NOT steal key focus, which would cancel the in-flight cross-app drag session).
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    let drag = DragCallbacks()

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @MainActor required init(rootView: Content) { super.init(rootView: rootView) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        drag.onDragEntered?(); return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { drag.onDragExited?() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFileURLs(sender)
        guard !urls.isEmpty else { return false }
        drag.onFilesDropped?(urls); return true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { drag.onDragExited?() }
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
        // Float above ordinary app windows and the menu bar, but stay BELOW the
        // screen-saver/shielding levels — windows that high don't receive drag-and-drop
        // events, which broke file drops onto the pill. `.statusBar` (just above the menu
        // bar) keeps the island on top of everything that matters while accepting drops.
        // We don't join fullscreen spaces — we hide while a fullscreen app is front
        // (see updateFullscreenVisibility) so the island never covers fullscreen video.
        level                       = .statusBar
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

        let hosting = FirstMouseHostingView(rootView:
            AnyView(NotchView(notchWidth: notchWidth, topInset: topInset).environmentObject(state))
        )
        hosting.frame = tracker.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = CGColor.clear

        tracker.addSubview(hosting)
        contentView = tracker

        // File drops: expand to the shelf on enter, accept files on drop. Wire both the
        // frontmost hosting view (the usual destination) and the tracker beneath it as a
        // backstop, so the collapsed pill reliably accepts drags.
        let onEnter:  () -> Void        = { [weak self] in self?.beginShelfDrag() }
        let onExit:   () -> Void        = { [weak self] in self?.state.isDragTargeted = false }
        let onDropped: ([URL]) -> Void  = { urls in
            Task { @MainActor in urls.forEach { ShelfStore.shared.add($0) } }
        }
        for v in [tracker as NSView, hosting] {
            v.registerForDraggedTypes(dropTypes)
        }
        tracker.drag.onDragEntered = onEnter
        tracker.drag.onDragExited  = onExit
        tracker.drag.onFilesDropped = onDropped
        hosting.drag.onDragEntered = onEnter
        hosting.drag.onDragExited  = onExit
        hosting.drag.onFilesDropped = onDropped

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
            let cH = lArea.height * 1.092            // ~9% taller than the notch strip (3% + 6%)
            let cx = (lArea.maxX + rArea.minX) / 2   // notch centre
            let eH = topInset + 34 + 24 + 188          // notch strip + navbar + gap + tab content

            // Top edge pinned to the bezel; the extra height grows straight down.
            compactRect = NSRect(x: cx - cW / 2, y: lArea.maxY - cH, width: cW, height: cH)
            hoverRect = inflatedCompact(compactRect, dw: 20, dh: 6)
            // Top edge stays pinned to the bezel — the card grows straight DOWN, no shift, no gap above.
            expandedRect = NSRect(x: cx - eW / 2, y: compactRect.maxY - eH, width: eW, height: eH)
        } else {
            // Non-notch Mac: one small pill centred at the top; expands into the same card.
            let menuBarH = screen.frame.height - screen.visibleFrame.height - screen.visibleFrame.origin.y
            notchWidth = 0
            topInset   = menuBarH
            let cW: CGFloat = 120
            let cH = menuBarH * 1.092                // ~9% taller than the menu bar (3% + 6%)
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

    // Expand straight to the shelf for an incoming file drag. Deliberately does NOT
    // call makeKey() — taking key focus mid-drag cancels the cross-app drag session,
    // which is what made drops fail before.
    func beginShelfDrag() {
        state.isDragTargeted = true
        state.tab = .shelf
        guard !state.isExpanded else { return }
        state.isExpanded = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(self.expandedRect, display: true)
        }
    }

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
