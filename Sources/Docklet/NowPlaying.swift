import AppKit
import Foundation
import SwiftUI

struct TrackInfo: Equatable {
    var title: String = ""
    var artist: String = ""
    var artwork: NSImage? = nil
    var duration: Double = 0
    var elapsed: Double = 0
    var isPlaying: Bool = false

    static func == (lhs: TrackInfo, rhs: TrackInfo) -> Bool {
        lhs.title == rhs.title && lhs.artist == rhs.artist &&
        lhs.isPlaying == rhs.isPlaying && lhs.duration == rhs.duration
    }
}

private struct ScriptOutput: Sendable {
    let stringValue: String?
    let data: Data?
}

// Reads now-playing state from Music.app / Spotify via AppleScript.
// (Apple gated the private MediaRemote now-playing API in macOS 15.4+, so scripting
// the player apps directly is the reliable path on current macOS.)
@MainActor
final class NowPlayingMonitor: ObservableObject {
    @Published var track = TrackInfo()
    @Published var displayElapsed: Double = 0
    @Published var tint: Color = .clear   // stable album-dominant colour (computed once per artwork)

    private var source = "Music"          // app to send transport commands to
    private var artKey = ""               // title+artist of the artwork we last fetched
    private var pollTimer: Timer?
    private var tickTimer: Timer?
    private var elapsedBase = 0.0
    private var elapsedBaseTime = Date()
    private var isPolling = false
    private var retryAfter = Date.distantPast

    private let asQueue = DispatchQueue(label: "com.docklet.applescript")

    private let metadataScript = """
    set sep to "<<S>>"
    set out to "NONE"
    -- Prefer an app that is actively playing over one that is merely paused.
    if application "Music" is running then
        tell application "Music"
            try
                if player state is playing then
                    set t to current track
                    set out to "Music" & sep & (get name of t) & sep & (get artist of t) & sep & (duration of t) & sep & (player position) & sep & (player state as text)
                end if
            end try
        end tell
    end if
    if out is "NONE" and application "Spotify" is running then
        tell application "Spotify"
            try
                if player state is playing then
                    set t to current track
                    set out to "Spotify" & sep & (get name of t) & sep & (get artist of t) & sep & ((duration of t) / 1000) & sep & (player position) & sep & (player state as text)
                end if
            end try
        end tell
    end if
    if out is "NONE" and application "Music" is running then
        tell application "Music"
            try
                if player state is not stopped then
                    set t to current track
                    set out to "Music" & sep & (get name of t) & sep & (get artist of t) & sep & (duration of t) & sep & (player position) & sep & (player state as text)
                end if
            end try
        end tell
    end if
    if out is "NONE" and application "Spotify" is running then
        tell application "Spotify"
            try
                if player state is not stopped then
                    set t to current track
                    set out to "Spotify" & sep & (get name of t) & sep & (get artist of t) & sep & ((duration of t) / 1000) & sep & (player position) & sep & (player state as text)
                end if
            end try
        end tell
    end if
    return out
    """

    init() {
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            pollTimer?.invalidate()
            tickTimer?.invalidate()
        }
    }

    // MARK: - Polling

    private func poll() {
        guard !isPolling, Date() >= retryAfter else { return }
        isPolling = true
        runScript(metadataScript) { [weak self] desc, denied in
            guard let self else { return }
            self.isPolling = false
            if denied {
                // A permission can be granted later in System Settings. Avoid hammering
                // Apple Events while still recovering without requiring an app restart.
                self.retryAfter = Date().addingTimeInterval(30)
                return
            }
            self.retryAfter = .distantPast
            self.apply(desc?.stringValue ?? "NONE")
        }
    }

    private func apply(_ raw: String) {
        guard raw != "NONE" else {
            if track != TrackInfo() { track = TrackInfo() }
            displayElapsed = 0
            tint = .clear
            artKey = ""
            stopTick()
            return
        }
        let f = raw.components(separatedBy: "<<S>>")
        guard f.count >= 6 else { return }

        source = f[0]
        let title    = f[1]
        let artist   = f[2]
        let rawDuration = Double(f[3]) ?? 0
        let duration = rawDuration.isFinite ? max(0, rawDuration) : 0
        let rawPosition = Double(f[4]) ?? 0
        let finitePosition = rawPosition.isFinite ? max(0, rawPosition) : 0
        let position = duration > 0 ? min(finitePosition, duration) : finitePosition
        let playing  = f[5].lowercased().contains("playing")

        let key = source + "|" + title + "|" + artist + "|" + String(duration)
        let needsArtwork = key != artKey

        var t = track
        t.title = title; t.artist = artist
        t.duration = duration; t.elapsed = position; t.isPlaying = playing
        if needsArtwork { t.artwork = nil }
        if needsArtwork || t != track || t.elapsed != track.elapsed { track = t }

        elapsedBase = position
        elapsedBaseTime = Date()
        displayElapsed = position
        playing ? startTick() : stopTick()

        if needsArtwork {
            artKey = key
            tint = .clear
            fetchArtwork(for: source, key: key)
        }
    }

    private func startTick() {
        guard tickTimer == nil else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let live = self.elapsedBase + Date().timeIntervalSince(self.elapsedBaseTime)
                self.displayElapsed = self.track.duration > 0
                    ? min(live, self.track.duration)
                    : live
            }
        }
    }
    private func stopTick() { tickTimer?.invalidate(); tickTimer = nil }

    // MARK: - Artwork

    private func fetchArtwork(for app: String, key: String) {
        if app == "Spotify" {
            runScript("tell application \"Spotify\" to get artwork url of current track") { [weak self] desc, _ in
                guard let self, let urlStr = desc?.stringValue, let url = URL(string: urlStr) else { return }
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    guard let data, let img = NSImage(data: data) else { return }
                    Task { @MainActor in self.setArtwork(img, for: key) }
                }.resume()
            }
        } else {
            runScript("tell application \"Music\" to get raw data of artwork 1 of current track") { [weak self] desc, _ in
                guard let self, let data = desc?.data, let img = NSImage(data: data) else { return }
                self.setArtwork(img, for: key)
            }
        }
    }

    private func setArtwork(_ img: NSImage, for key: String) {
        guard artKey == key else { return }
        track.artwork = img
        tint = NowPlayingMonitor.dominantColor(of: img)
    }

    // Deterministic average colour over a small fixed grid (no randomness → no flicker).
    static func dominantColor(of image: NSImage) -> Color {
        guard let tiff = image.tiffRepresentation, let bm = NSBitmapImageRep(data: tiff) else { return .clear }
        let w = max(1, bm.pixelsWide), h = max(1, bm.pixelsHigh)
        let steps = 8
        var r = 0.0, g = 0.0, b = 0.0, count = 0.0
        for i in 0..<steps {
            for j in 0..<steps {
                let x = (w - 1) * i / (steps - 1)
                let y = (h - 1) * j / (steps - 1)
                guard let c = bm.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0, a: CGFloat = 0
                c.getRed(&cr, green: &cg, blue: &cb, alpha: &a)
                r += Double(cr); g += Double(cg); b += Double(cb); count += 1
            }
        }
        guard count > 0 else { return .clear }
        return Color(red: r / count, green: g / count, blue: b / count)
    }

    // MARK: - Transport

    func togglePlayPause() { command("playpause") }
    func next()            { command("next track") }
    func prev()            { command("previous track") }

    /// Scrub to an absolute position (seconds). Both Music and Spotify expose
    /// `player position` in seconds, so the same command works for either.
    func seek(to seconds: Double) {
        guard track.duration > 0, seconds.isFinite,
              source == "Music" || source == "Spotify" else { return }
        let target = min(max(0, seconds), track.duration)
        // Optimistically update the UI so the bar tracks the cursor immediately.
        elapsedBase = target
        elapsedBaseTime = Date()
        displayElapsed = target
        runScript("tell application \"\(source)\" to set player position to \(target)") { [weak self] _, _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func command(_ cmd: String) {
        guard !track.title.isEmpty, source == "Music" || source == "Spotify" else { return }
        runScript("tell application \"\(source)\" to \(cmd)") { [weak self] _, _ in
            Task { @MainActor in self?.poll() }
        }
    }

    // MARK: - AppleScript runner

    private func runScript(
        _ src: String,
        done: @escaping @MainActor @Sendable (ScriptOutput?, _ denied: Bool) -> Void
    ) {
        asQueue.async {
            var err: NSDictionary?
            let result = NSAppleScript(source: src)?.executeAndReturnError(&err)
            let denied = (err?[NSAppleScript.errorNumber] as? Int) == -1743
            let output = result.map {
                ScriptOutput(stringValue: $0.stringValue, data: $0.data)
            }
            DispatchQueue.main.async { done(output, denied) }
        }
    }
}
