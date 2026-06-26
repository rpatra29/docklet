import SwiftUI
import AppKit
import AVFoundation
import CoreLocation

// MARK: - First-run onboarding

private let onboardKey = "didOnboardV1"

enum Onboarding {
    static var needsOnboarding: Bool { !UserDefaults.standard.bool(forKey: onboardKey) }
    static func markComplete() { UserDefaults.standard.set(true, forKey: onboardKey) }
}

@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: OnboardingView { [weak self] in
                Onboarding.markComplete()
                self?.window?.close()
                self?.window = nil
            })
            let w = NSWindow(contentViewController: hosting)
            w.title = "Welcome to Docklet"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 460, height: 520))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - View

struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var page = 0
    private let pageCount = 3

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            RadialGradient(colors: [Color.blue.opacity(0.18), .clear],
                           center: .top, startRadius: 0, endRadius: 420)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Group {
                    switch page {
                    case 0:  WelcomePage()
                    case 1:  PermissionsPage()
                    default: FinishPage()
                    }
                }
                .transition(.opacity)
                .frame(maxWidth: .infinity)
                Spacer(minLength: 0)

                // Page dots
                HStack(spacing: 6) {
                    ForEach(0..<pageCount, id: \.self) { i in
                        Circle()
                            .fill(Color.white.opacity(i == page ? 0.9 : 0.25))
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.bottom, 18)

                // Navigation
                HStack {
                    if page > 0 {
                        Button("Back") { withAnimation { page -= 1 } }
                            .buttonStyle(.plain)
                            .foregroundColor(.white.opacity(0.55))
                    }
                    Spacer()
                    Button(page == pageCount - 1 ? "Get Started" : "Continue") {
                        if page == pageCount - 1 { onFinish() }
                        else { withAnimation { page += 1 } }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 28)
            }
        }
        .frame(width: 460, height: 520)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Pages

private struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "oval.fill")
                .font(.system(size: 56))
                .foregroundStyle(.white)
                .shadow(color: .blue.opacity(0.5), radius: 18)
            Text("Welcome to Docklet")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
            Text("A live widget that lives in your notch — music, a drag-and-drop shelf, weather, clipboard history and quick voice notes, always a glance away.")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 44)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PermissionsPage: View {
    @StateObject private var perms = PermissionState()

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("Grant a few permissions")
                    .font(.system(size: 20, weight: .bold)).foregroundColor(.white)
                Text("Each is optional — Docklet works without them, but they unlock the matching tabs.")
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.55))
                    .multilineTextAlignment(.center).padding(.horizontal, 36)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                PermissionRow(
                    icon: "music.note", tint: .pink,
                    title: "Music", subtitle: "See what's playing & control it",
                    granted: perms.musicRequested,
                    actionLabel: "Connect"
                ) { perms.requestMusic() }

                PermissionRow(
                    icon: "mic.fill", tint: .orange,
                    title: "Microphone", subtitle: "Record quick voice notes",
                    granted: perms.micGranted,
                    actionLabel: "Enable"
                ) { perms.requestMic() }

                PermissionRow(
                    icon: "location.fill", tint: .blue,
                    title: "Location", subtitle: "Show accurate local weather",
                    granted: perms.locationRequested,
                    actionLabel: "Enable"
                ) { perms.requestLocation() }
            }
            .padding(.horizontal, 30)
        }
        .onAppear { perms.refresh() }
    }
}

private struct FinishPage: View {
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 50)).foregroundStyle(.green)
            Text("You're all set")
                .font(.system(size: 22, weight: .bold)).foregroundColor(.white)
            Text("Click the pill to expand it. Hover the menu-bar icon's menu for Settings, where you can pick tabs, colours and more.")
                .font(.system(size: 13)).foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center).padding(.horizontal, 40)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: Binding(
                get: { launchAtLogin },
                set: { LoginItem.set($0); launchAtLogin = LoginItem.isEnabled }
            )) {
                Text("Launch Docklet at login").foregroundColor(.white.opacity(0.85))
            }
            .toggleStyle(.switch)
            .tint(.blue)
            .padding(.horizontal, 60)
            .padding(.top, 4)
        }
    }
}

// MARK: - Pieces

private struct PermissionRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let granted: Bool
    let actionLabel: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(tint.opacity(0.85)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                Text(subtitle).font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18)).foregroundStyle(.green)
            } else {
                Button(actionLabel, action: action)
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.black)
            .padding(.horizontal, 20).padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.7 : 0.95)))
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.18)))
    }
}

// MARK: - Permission requests

@MainActor
private final class PermissionState: ObservableObject {
    @Published var micGranted = false
    @Published var locationRequested = false
    @Published var musicRequested = false

    private let asQueue = DispatchQueue(label: "com.docklet.onboarding")

    func refresh() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let loc = CLLocationManager().authorizationStatus
        locationRequested = (loc != .notDetermined)
    }

    func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in self?.micGranted = granted }
        }
    }

    func requestLocation() {
        // refresh() drives CoreLocation's auth prompt when status is notDetermined.
        WeatherMonitor.shared.refresh()
        locationRequested = true
    }

    // Trigger the Apple-Events automation prompt for whichever player is running,
    // without launching either app.
    func requestMusic() {
        musicRequested = true
        let src = """
        if application "Music" is running then tell application "Music" to get player state
        if application "Spotify" is running then tell application "Spotify" to get player state
        """
        asQueue.async {
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
        }
    }
}
