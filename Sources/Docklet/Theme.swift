import SwiftUI
import AppKit

// MARK: - Color <-> hex helpers (used by the custom accent colour setting)

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(.sRGB,
                  red:   Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8)  & 0xFF) / 255,
                  blue:  Double(v & 0xFF) / 255,
                  opacity: 1)
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let r = Int(round(ns.redComponent   * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent  * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
