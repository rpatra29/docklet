import SwiftUI
import AVFoundation

// MARK: - Recorder

@MainActor
final class CaptureMonitor: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var duration: Double = 0
    @Published var permissionDenied = false

    private var recorder: AVAudioRecorder?
    private var ticker: Timer?

    func toggle() {
        isRecording ? stop() : requestAndStart()
    }

    private func requestAndStart() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if granted { self.start() } else { self.permissionDenied = true }
            }
        }
    }

    private func start() {
        let dir = FileManager.default.temporaryDirectory
        let name = "capture-\(Int(Date().timeIntervalSince1970)).m4a"
        let url = dir.appendingPathComponent(name)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        guard let rec = try? AVAudioRecorder(url: url, settings: settings) else { return }
        rec.prepareToRecord()
        rec.record()
        recorder = rec
        duration = 0
        isRecording = true
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.duration += 0.1 }
        }
    }

    private func stop() {
        ticker?.invalidate(); ticker = nil
        guard let rec = recorder else { return }
        rec.stop()
        isRecording = false
        let url = rec.url
        recorder = nil
        // Auto-add to shelf, then collapse so the confirmation flash is visible on the pill.
        Task { @MainActor in
            ShelfStore.shared.add(url)
            PillState.shared?.onExpandRequest?(false)
            PillState.shared?.flash(icon: "waveform", text: "Voice note saved")
        }
    }
}

// MARK: - View

struct CaptureView: View {
    @StateObject private var monitor = CaptureMonitor()

    var body: some View {
        VStack(spacing: 14) {
            if monitor.permissionDenied {
                VStack(spacing: 6) {
                    Image(systemName: "mic.slash")
                        .font(.system(size: 24)).foregroundColor(.white.opacity(0.4))
                    Text("Microphone access denied")
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                    Text("Enable in System Settings → Privacy → Microphone")
                        .font(.system(size: 9)).foregroundColor(.white.opacity(0.3))
                        .multilineTextAlignment(.center)
                }
            } else {
                // Big record button
                Button { monitor.toggle() } label: {
                    ZStack {
                        Circle()
                            .fill(monitor.isRecording ? Color.red.opacity(0.85) : Color.white.opacity(0.12))
                            .frame(width: 56, height: 56)
                            .shadow(color: monitor.isRecording ? .red.opacity(0.5) : .clear, radius: 10)
                        Image(systemName: monitor.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(.plain)
                .scaleEffect(monitor.isRecording ? 1.06 : 1.0)
                .animation(.spring(response: 0.35, dampingFraction: 0.6), value: monitor.isRecording)

                if monitor.isRecording {
                    HStack(spacing: 5) {
                        Circle().fill(Color.red)
                            .frame(width: 5, height: 5)
                            .opacity(Double(Int(monitor.duration * 2) % 2)) // blink
                        Text(formatDuration(monitor.duration))
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.9))
                    }
                } else {
                    Text("Tap to record — saved to Shelf")
                        .font(.system(size: 10)).foregroundColor(.white.opacity(0.38))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formatDuration(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
