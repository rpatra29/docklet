import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Temporary drag-and-drop storage

@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()
    @Published var items: [URL] = []

    private static let key = "shelfItemPaths"

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        items = paths.compactMap { path -> URL? in
            let url = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: path) ? url : nil
        }
    }

    func add(_ url: URL) {
        guard url.isFileURL, !items.contains(url) else { return }
        items.append(url)
        persist()
    }
    func remove(_ url: URL) { items.removeAll { $0 == url }; persist() }
    func clear() { items.removeAll(); persist() }

    private func persist() {
        UserDefaults.standard.set(items.map(\.path), forKey: Self.key)
    }
}

struct ShelfView: View {
    @StateObject private var store = ShelfStore.shared
    @EnvironmentObject var state: PillState

    var body: some View {
        ZStack {
            if store.items.isEmpty {
                emptyState
            } else {
                filledState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Dashed highlight while a drag hovers anywhere on the widget
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                .foregroundColor(.white.opacity(state.isDragTargeted ? 0.55 : 0))
                .padding(8)
                .animation(.easeOut(duration: 0.15), value: state.isDragTargeted)
        )
    }

    var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 22, weight: .light))
                .foregroundColor(.white.opacity(state.isDragTargeted ? 0.9 : 0.4))
            Text("Drop files here")
                .font(.system(size: 11)).foregroundColor(.white.opacity(0.45))
        }
    }

    var filledState: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(store.items, id: \.self) { url in
                        ShelfItemView(url: url) { store.remove(url) }
                    }
                }
                .padding(.horizontal, 16)
            }
            HStack {
                Text("\(store.items.count) item\(store.items.count == 1 ? "" : "s")")
                    .font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
                Spacer()
                Button { store.clear() } label: {
                    Text("Clear All")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
    }
}

struct ShelfItemView: View {
    let url: URL
    let onRemove: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: icon)
                .resizable().interpolation(.high)
                .frame(width: 38, height: 38)
            Text(url.lastPathComponent)
                .font(.system(size: 8)).foregroundColor(.white.opacity(0.6))
                .lineLimit(1).truncationMode(.middle).frame(width: 54)
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(hover ? 0.12 : 0.05)))
        .overlay(alignment: .topTrailing) {
            if hover {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
            }
        }
        .onHover { hover = $0 }
        // Drag the real file back out — into Finder, Mail, any app
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
    }

    var icon: NSImage {
        let img = NSWorkspace.shared.icon(forFile: url.path)
        img.size = NSSize(width: 38, height: 38)
        return img
    }
}
