import SwiftUI
import AppKit

/// Threadly design tokens — the warm family accent shared with the product
/// sites (#C15F3C), plus the soft highlight derived from it.
enum DesignTokens {
    /// Terracotta accent shared with the family sites (#C15F3C).
    static let accent = Color(red: 0xC1 / 255.0, green: 0x5F / 255.0, blue: 0x3C / 255.0)

    /// Soft highlight background (selected rows, search hits).
    /// Light: #F7E5DD · Dark: #3B2A22.
    static let accentSoft = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(red: 0x3B / 255.0, green: 0x2A / 255.0, blue: 0x22 / 255.0, alpha: 1)
        }
        return NSColor(red: 0xF7 / 255.0, green: 0xE5 / 255.0, blue: 0xDD / 255.0, alpha: 1)
    })
}

extension Color {
    /// Forum category colors arrive as bare 6-digit hex strings ("0088CC").
    init?(forumHex: String) {
        guard forumHex.count == 6, let value = UInt32(forumHex, radix: 16) else {
            return nil
        }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}
