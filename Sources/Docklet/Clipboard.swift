import SwiftUI
import AppKit

// MARK: - Model

struct ClipItem: Identifiable {
    let id = UUID()
    let text: String?
    let image: NSImage?
    let date: Date
}

// MARK: - Monitor

@MainActor
final class ClipboardMonitor: ObservableObject {
    static let shared = ClipboardMonitor()

    @Published var items: [ClipItem] = []

    private var lastChangeCount: Int
    private var timer: Timer?

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    deinit { timer?.invalidate() }

    private func check() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        if let text = pb.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if items.first?.text == text { return }   // deduplicate
            insert(ClipItem(text: text, image: nil, date: Date()))
        } else if let data = pb.data(forType: .tiff) ?? pb.data(forType: .png),
                  let img = NSImage(data: data) {
            insert(ClipItem(text: nil, image: img, date: Date()))
        }
    }

    private func insert(_ item: ClipItem) {
        items.insert(item, at: 0)
        if items.count > 20 { items.removeLast() }
    }

    func copy(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let t = item.text  { pb.setString(t, forType: .string) }
        if let i = item.image { pb.writeObjects([i]) }
        lastChangeCount = pb.changeCount   // don't re-capture our own copy
    }

    func remove(id: UUID) { items.removeAll { $0.id == id } }
    func clear()          { items.removeAll() }
}

// MARK: - View

struct ClipboardView: View {
    @StateObject private var monitor = ClipboardMonitor.shared

    var body: some View {
        VStack(spacing: 0) {
            if monitor.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 22, weight: .light))
                        .foregroundColor(.white.opacity(0.3))
                    Text("Nothing copied yet")
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Text("\(monitor.items.count) item\(monitor.items.count == 1 ? "" : "s")")
                        .font(.system(size: 10)).foregroundColor(.white.opacity(0.35))
                    Spacer()
                    Button { monitor.clear() } label: {
                        Text("Clear").font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 2)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(monitor.items) { item in
                            ClipItemRow(item: item,
                                onCopy:   { monitor.copy(item) },
                                onRemove: { monitor.remove(id: item.id) })
                        }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ClipItemRow: View {
    let item: ClipItem
    let onCopy: () -> Void
    let onRemove: () -> Void
    @State private var hover = false
    @State private var flashCheck = false

    var body: some View {
        HStack(spacing: 8) {
            if let img = item.image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text("Image").font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
            } else if let text = item.text {
                Text(text)
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.85))
                    .lineLimit(2).truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if hover {
                Group {
                    if flashCheck {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold)).foregroundColor(.green)
                    } else {
                        Button {
                            onCopy()
                            flashCheck = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { flashCheck = false }
                        } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.45))
                        }.buttonStyle(.plain)
                    }
                }
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.35))
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hover ? 0.1 : 0.04)))
        .onHover { hover = $0 }
        .onTapGesture {
            onCopy()
            flashCheck = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { flashCheck = false }
        }
    }
}
