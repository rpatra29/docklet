import SwiftUI
import AppKit

// MARK: - Model

struct ClipItem: Identifiable {
    let id = UUID()
    let text: String?
    let image: NSImage?
    let date: Date
    var pinned: Bool = false
}

// MARK: - Monitor

@MainActor
final class ClipboardMonitor: ObservableObject {
    static let shared = ClipboardMonitor()

    @Published var items: [ClipItem] = []

    /// Pinned items first (newest-first within each group), so pins stay at the top.
    var ordered: [ClipItem] { items.filter(\.pinned) + items.filter { !$0.pinned } }

    private let maxUnpinnedItems = 20
    private var lastChangeCount: Int
    private var timer: Timer?

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    deinit { MainActor.assumeIsolated { timer?.invalidate() } }

    private func check() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        if let text = pb.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let existing = items.firstIndex(where: { $0.text == text }) {
                // Re-copying an older entry makes it recent without losing its pin.
                items.insert(items.remove(at: existing), at: 0)
                return
            }
            insert(ClipItem(text: text, image: nil, date: Date()))
        } else if let data = pb.data(forType: .tiff) ?? pb.data(forType: .png),
                  let img = NSImage(data: data) {
            insert(ClipItem(text: nil, image: img, date: Date()))
        }
    }

    private func insert(_ item: ClipItem) {
        items.insert(item, at: 0)
        trim()
    }

    // Keep a full rolling history in addition to pins. Otherwise pinning 20 items
    // would silently prevent every new clipboard item from being captured.
    private func trim() {
        while items.lazy.filter({ !$0.pinned }).count > maxUnpinnedItems,
              let idx = items.lastIndex(where: { !$0.pinned }) {
            items.remove(at: idx)
        }
    }

    func copy(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let t = item.text  { pb.setString(t, forType: .string) }
        if let i = item.image { pb.writeObjects([i]) }
        lastChangeCount = pb.changeCount   // don't re-capture our own copy
    }

    func togglePin(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].pinned.toggle()
        trim()
    }

    func remove(id: UUID) { items.removeAll { $0.id == id } }
    // Clear only unpinned items — pins are intentionally kept.
    func clear()          { items.removeAll { !$0.pinned } }
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
                        ForEach(monitor.ordered) { item in
                            ClipItemRow(item: item,
                                onCopy:   { monitor.copy(item) },
                                onPin:    { monitor.togglePin(id: item.id) },
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
    let onPin: () -> Void
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
            // A persistent pin glyph marks pinned rows even when not hovered.
            if item.pinned && !hover {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9)).foregroundColor(.white.opacity(0.4))
                    .rotationEffect(.degrees(45))
            }
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
                Button(action: onPin) {
                    Image(systemName: item.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 10))
                        .foregroundColor(item.pinned ? .yellow.opacity(0.85) : .white.opacity(0.45))
                        .rotationEffect(.degrees(45))
                }.buttonStyle(.plain)
                    .help(item.pinned ? "Unpin" : "Pin — keep across history")
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.35))
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(Color.white.opacity(item.pinned ? (hover ? 0.12 : 0.07) : (hover ? 0.1 : 0.04))))
        .onTapGesture {
            onCopy()
            flashCheck = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { flashCheck = false }
        }
        .onHover { hover = $0 }
    }
}
