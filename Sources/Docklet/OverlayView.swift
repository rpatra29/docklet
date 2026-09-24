import SwiftUI

// MARK: - Glass blur

struct LiquidGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// U-shaped path: top-left → down left edge → bottom → up right edge → top-right (no top edge).
// Trimming this from 0→progressFraction traces the outline left-to-right.
struct IslandProgressShape: Shape {
    var cornerRadius: CGFloat = 12
    // Pull the path in by half the stroke width so the line sits flush *inside*
    // the pill edge instead of straddling it (which makes it look detached on the
    // short docked pill, where the bottom edge meets the menu-bar boundary).
    var inset: CGFloat = 1

    func path(in rect0: CGRect) -> Path {
        // Inset the sides and bottom; leave the top open (the top edge isn't drawn).
        let rect = CGRect(x: rect0.minX + inset, y: rect0.minY,
                          width: max(0, rect0.width - inset * 2),
                          height: max(0, rect0.height - inset))
        var p = Path()
        let r = max(0, min(cornerRadius - inset, rect.height / 2, rect.width / 2))
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
                 radius: r, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
                 radius: r, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

// One unified widget shape:
//  • compact  → flat top (hugs the bezel / extends the notch), rounded bottom corners
//  • expanded → fully rounded floating card
func notchShape(isExpanded: Bool) -> UnevenRoundedRectangle {
    // Always flat on top (flush with the bezel / notch) and rounded only on the bottom,
    // so the widget grows straight down with nothing floating above it.
    let r: CGFloat = isExpanded ? 24 : 12
    return UnevenRoundedRectangle(
        topLeadingRadius:     0,
        bottomLeadingRadius:  r,
        bottomTrailingRadius: r,
        topTrailingRadius:    0,
        style: .continuous
    )
}

// MARK: - THE single notch widget

struct NotchView: View {
    @EnvironmentObject var state: PillState
    @StateObject private var np = NowPlayingMonitor()
    @StateObject private var sysmon = SystemMonitor()
    @StateObject private var weather = WeatherMonitor.shared

    // Width of the physical notch to leave pure-black in the compact middle (0 on non-notch Macs)
    let notchWidth: CGFloat
    // Height of the notch / menu bar that the expanded content must sit below
    let topInset: CGFloat

    @State private var isHovered = false
    @State private var eq: [CGFloat] = [5, 9, 6, 10, 7]
    private let eqTimer = Timer.publish(every: 0.16, on: .main, in: .common).autoconnect()

    // Navbar row height. The opaque black header = notch strip + navbar.
    private let navH: CGFloat = 34
    private var headerHeight: CGFloat { topInset + navH }

    var tint: Color { np.tint }
    // Resolved accent — album artwork colour or the user's custom colour.
    var accent: Color { state.accent(albumTint: np.tint) }
    var progressFraction: CGFloat {
        CGFloat(min(max(np.displayElapsed / max(np.track.duration, 1), 0), 1))
    }

    var body: some View {
        // Top-aligned so the widget grows DOWN from the top line, not out from its centre.
        ZStack(alignment: .top) {
            background

            if state.isExpanded {
                expandedContent
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))
            } else {
                compactBar
                    .transition(.opacity.animation(.easeInOut(duration: 0.12)))
            }
        }
        .clipShape(notchShape(isExpanded: state.isExpanded))
        // Same curve + duration as the window frame animation so they move as one.
        .animation(.easeOut(duration: 0.4), value: state.isExpanded)
        // Music progress traced along left → bottom → right edges of the compact pill
        .overlay(alignment: .top) {
            if !state.isExpanded && np.track.duration > 0 {
                IslandProgressShape(cornerRadius: 12)
                    .trim(from: 0, to: progressFraction)
                    .stroke(
                        accent == .clear ? Color.white.opacity(0.75) : accent.opacity(0.9),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .animation(.linear(duration: 0.5), value: np.displayElapsed)
            }
        }
        // Soft outline pulse while a notification toast is showing on the compact pill.
        .overlay {
            if state.toast != nil && !state.isExpanded {
                notchShape(isExpanded: false)
                    .stroke(accent == .clear ? Color.white.opacity(0.5) : accent.opacity(0.7),
                            lineWidth: 1.5)
                    .transition(.opacity)
            }
        }
        // File drag-and-drop is handled at the AppKit layer (OverlayPanel's content view)
        // so it works reliably even while collapsed — see MouseTrackingView's drag methods.
        // Subtle grow on hover in compact mode — the whole pill enlarges by
        // animating the actual window frame (see OverlayPanel.setHovered), so the
        // growth isn't clipped at the window edges the way a scaleEffect would be.
        // Hover behaviour: expand-on-hover takes priority; otherwise the whole pill
        // enlarges (the window frame grows so nothing is clipped).
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                if state.isExpanded { return }
                if state.expandOnHover { state.onExpandRequest?(true) }
                else if state.enlargeOnHover { state.onHoverRequest?(true) }
            } else {
                if state.isExpanded {
                    if state.expandOnHover { state.onExpandRequest?(false) }
                } else if state.enlargeOnHover {
                    state.onHoverRequest?(false)
                }
            }
        }
        .onReceive(eqTimer) { _ in
            let playing = np.track.isPlaying
            withAnimation(.easeInOut(duration: 0.14)) {
                eq = eq.map { _ in playing ? CGFloat.random(in: 3...13) : CGFloat.random(in: 2...3) }
            }
        }
    }

    // Compact = pure black so it merges with the notch hardware.
    // Expanded = soft glass card with a faint album-colour glow.
    var background: some View {
        ZStack(alignment: .top) {
            if state.isExpanded {
                LiquidGlass()
                Color.black.opacity(0.82)
                // Accent glow, anchored behind the album art (music tab only).
                if state.glowEnabled && state.tab == .music && accent != .clear {
                    RadialGradient(colors: [accent.opacity(0.32), .clear],
                                   center: UnitPoint(x: 0.16, y: 0.62),
                                   startRadius: 0, endRadius: 300)
                }
                // Header: SOLID black across the notch / menu-bar strip (so the menu bar can never
                // bleed through), then FADES into the glass content — no hard edge, so the
                // album-colour glow blends straight through with no seam line.
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: min(0.95, topInset / max(headerHeight, 1))),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: headerHeight)
                .allowsHitTesting(false)
            } else {
                Color.black
            }
        }
    }

    // MARK: Compact — one bar that straddles the notch (art | notch | waveform)

    var compactBar: some View {
        GeometryReader { geo in
            let sideW = max(0, (geo.size.width - notchWidth) / 2)
            let barH = geo.size.height
            // Thumbnail sits comfortably inside the pill with even margins, rather than
            // filling the full height (which made it look oversized/cramped).
            let artSide = max(0, barH * 0.62)
            let noMusic = np.track.title.isEmpty
            // Inline transport appears on hover while music is loaded — no need to expand.
            let showControls = isHovered && !noMusic

            if let toast = state.toast {
                toastBar(toast, sideW: sideW)
            } else {
                HStack(spacing: 0) {
                    // Left of notch: album art (with hover play/pause) when playing, idle glyph when idle
                    Group {
                        if noMusic {
                            idleLeft.padding(.trailing, 6)
                        } else {
                            ZStack {
                                artworkThumb(side: artSide)
                                if showControls {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Color.black.opacity(0.5))
                                        .frame(width: artSide, height: artSide)
                                    compactCtrl(np.track.isPlaying ? "pause.fill" : "play.fill", 11) {
                                        np.togglePlayPause()
                                    }
                                }
                            }
                            .padding(.trailing, 6)
                        }
                    }
                    .frame(width: sideW, alignment: .trailing)

                    // Behind the physical notch: stays pure black
                    Color.black.frame(width: notchWidth)

                    // Right of notch: prev/next on hover, waveform while playing, idle value otherwise
                    Group {
                        if noMusic {
                            idleRight.padding(.leading, 6)
                        } else if showControls {
                            HStack(spacing: 1) {
                                compactCtrl("backward.fill", 10) { np.prev() }
                                compactCtrl("forward.fill", 10) { np.next() }
                            }
                            .padding(.leading, 2)
                        } else {
                            HStack(alignment: .center, spacing: 2.5) {
                                ForEach(Array(eq.enumerated()), id: \.offset) { _, h in
                                    Capsule()
                                        .fill(np.track.isPlaying ? Color.white.opacity(0.75) : Color.white.opacity(0.28))
                                        .frame(width: 2.5, height: h)
                                        .animation(.easeInOut(duration: 0.14), value: h)
                                }
                            }
                            .padding(.leading, 6)
                        }
                    }
                    .frame(width: sideW, alignment: .leading)
                }
            }
        }
    }

    // Album art thumbnail, falling back to a music-note placeholder.
    @ViewBuilder func artworkThumb(side: CGFloat) -> some View {
        if let img = np.track.artwork {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            ZStack {
                Color.white.opacity(0.08)
                Image(systemName: "music.note")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }

    // A small transport button sized for the compact pill.
    func compactCtrl(_ icon: String, _ size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .heavy))
                .foregroundColor(.white.opacity(0.92))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Transient notification laid out like the compact bar: icon left of the notch, text right.
    func toastBar(_ toast: PillState.Toast, sideW: CGFloat) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Image(systemName: toast.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(accent == .clear ? .white : accent)
            }
            .frame(width: sideW, alignment: .trailing)
            .padding(.trailing, 6)

            Color.black.frame(width: notchWidth)

            HStack(spacing: 0) {
                Text(toast.text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(width: sideW, alignment: .leading)
            .padding(.leading, 6)
        }
        .transition(.opacity)
    }

    // MARK: Compact idle content (weather / clock / battery / nothing)

    @ViewBuilder var idleLeft: some View {
        switch state.idleContent {
        case .weather:
            Image(systemName: WeatherMonitor.symbol(for: weather.current.code))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(WeatherMonitor.tint(for: weather.current.code))
                .shadow(color: WeatherMonitor.tint(for: weather.current.code).opacity(0.6), radius: 4)
        case .clock:
            Image(systemName: "clock")
                .font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.6))
        case .battery:
            Image(systemName: batterySymbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(sysmon.isCharging ? .green : .white.opacity(0.75))
        case .none:
            Color.clear.frame(width: 1)
        }
    }

    @ViewBuilder var idleRight: some View {
        switch state.idleContent {
        case .weather:
            Text(weather.status == .loaded ? state.temp(weather.current.tempC) : "––")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.8))
        case .clock:
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
            }
        case .battery:
            Text(sysmon.battery >= 0 ? "\(Int(sysmon.battery * 100))%" : "––")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.8))
        case .none:
            Color.clear.frame(width: 1)
        }
    }

    private var batterySymbol: String {
        let pct = sysmon.battery
        if sysmon.isCharging { return "battery.100.bolt" }
        switch pct {
        case ..<0:     return "bolt.slash"
        case ..<0.15:  return "battery.0"
        case ..<0.45:  return "battery.25"
        case ..<0.75:  return "battery.50"
        case ..<0.95:  return "battery.75"
        default:       return "battery.100"
        }
    }


    // MARK: Expanded — header navbar + sliding tab content

    var expandedContent: some View {
        VStack(spacing: 0) {
            // Notch / menu-bar clearance + navbar (both sit on the opaque black header)
            Color.clear.frame(height: topInset)
            navbar.frame(height: navH)

            // Breathing room between the navbar and the tab content
            Spacer().frame(height: 24)

            // Sliding tab content
            ZStack {
                switch state.tab {
                case .music:
                    musicPlayer
                        .transition(.move(edge: .leading).combined(with: .opacity))
                case .shelf:
                    ShelfView()
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                case .weather:
                    WeatherView()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                case .capture:
                    CaptureView()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                case .clipboard:
                    ClipboardView()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(.easeInOut(duration: 0.3), value: state.tab)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // Centred row of only the user-enabled tabs.
    var navbar: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                ForEach(state.visibleTabs) { t in
                    tabButton(t, t.icon, t.title)
                }
            }
            .padding(3)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            Spacer(minLength: 0)
        }
    }

    func tabButton(_ t: PillState.Tab, _ icon: String, _ label: String) -> some View {
        let active = state.tab == t
        return Button {
            withAnimation(.easeInOut(duration: 0.3)) { state.tab = t }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(active ? .black : .white.opacity(0.55))
                .frame(width: 40, height: 28)
                .background(RoundedRectangle(cornerRadius: 11).fill(active ? Color.white.opacity(0.92) : .clear))
                .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .help(label)
    }

    var musicPlayer: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    if let img = np.track.artwork {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.white.opacity(0.07)
                        Image(systemName: "music.note").font(.system(size: 18))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                .shadow(color: accent.opacity(0.45), radius: 8, y: 2)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(np.track.title.isEmpty ? "Nothing Playing" : np.track.title)
                                .font(.system(size: 13, weight: .bold)).foregroundColor(.white).lineLimit(1)
                            Text(np.track.artist.isEmpty ? "—" : np.track.artist)
                                .font(.system(size: 11)).foregroundColor(.white.opacity(0.55)).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        waveformIndicator
                    }
                    progressRow
                }
            }
            controlsRow
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    var waveformIndicator: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(eq.enumerated()), id: \.offset) { _, h in
                Capsule()
                    .fill(np.track.isPlaying ? Color.white.opacity(0.7) : Color.white.opacity(0.25))
                    .frame(width: 2.5, height: h)
                    .animation(.easeInOut(duration: 0.14), value: h)
            }
        }
        .frame(height: 13)
    }

    var progressRow: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15)).frame(height: 3)
                    Capsule().fill(accent == .clear ? Color.white.opacity(0.9) : accent)
                        .frame(width: geo.size.width * progressFraction, height: 3)
                        .animation(.linear(duration: 0.5), value: np.displayElapsed)
                }
                .frame(height: 14)                 // taller invisible hit area
                .contentShape(Rectangle())
                // Click or drag anywhere on the bar to scrub.
                .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                    let f = min(max(0, v.location.x / max(geo.size.width, 1)), 1)
                    np.seek(to: f * np.track.duration)
                })
            }.frame(height: 14)
            HStack {
                Text(fmt(np.displayElapsed)).font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.4))
                Spacer()
                Text(fmt(np.track.duration)).font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.4))
            }
        }
    }

    var controlsRow: some View {
        HStack(spacing: 42) {
            ctrlBtn("backward.fill", 16, .white) { np.prev() }
            ctrlBtn(np.track.isPlaying ? "pause.fill" : "play.fill", 22, .white) { np.togglePlayPause() }
            ctrlBtn("forward.fill", 16, .white) { np.next() }
        }
        .padding(.horizontal, 6)
        .disabled(np.track.title.isEmpty)
        .opacity(np.track.title.isEmpty ? 0.35 : 1)
    }

    func ctrlBtn(_ icon: String, _ sz: CGFloat, _ color: Color, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Image(systemName: icon).font(.system(size: sz, weight: .semibold)).foregroundColor(color)
        }.buttonStyle(.plain)
    }

    func fmt(_ s: Double) -> String {
        guard s.isFinite else { return "0:00" }
        let t = Int(max(0, s))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
