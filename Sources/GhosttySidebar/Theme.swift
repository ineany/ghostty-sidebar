import AppKit
import SwiftUI

/// Catppuccin Mocha, the theme Ghostty is configured with on this machine.
/// https://catppuccin.com/palette
enum Mocha {
    static let rosewater = Color(hex: 0xf5e0dc)
    static let mauve     = Color(hex: 0xcba6f7)
    static let red       = Color(hex: 0xf38ba8)
    static let peach     = Color(hex: 0xfab387)
    static let yellow    = Color(hex: 0xf9e2af)
    static let green     = Color(hex: 0xa6e3a1)
    static let sky       = Color(hex: 0x89dceb)
    static let teal      = Color(hex: 0x94e2d5)
    static let blue      = Color(hex: 0x89b4fa)
    static let lavender  = Color(hex: 0xb4befe)
    static let text      = Color(hex: 0xcdd6f4)
    static let subtext1  = Color(hex: 0xbac2de)
    static let subtext0  = Color(hex: 0xa6adc8)
    static let overlay1  = Color(hex: 0x7f849c)
    static let overlay0  = Color(hex: 0x6c7086)
    static let surface2  = Color(hex: 0x585b70)
    static let surface1  = Color(hex: 0x45475a)
    static let surface0  = Color(hex: 0x313244)
    static let base      = Color(hex: 0x1e1e2e)
    static let mantle    = Color(hex: 0x181825)
    static let crust     = Color(hex: 0x11111b)

    /// Same opacity as `background-opacity` in the Ghostty config.
    static let backgroundOpacity = 0.93
}

/// Fonts. D2Coding is the Ghostty font here; SwiftUI falls back to the system
/// font if it is not installed, so the monospaced variant is chosen explicitly.
enum Typo {
    static let monoFamily = "D2Coding ligature"
    static let hasMono = NSFont(name: monoFamily, size: 12) != nil

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        hasMono ? .custom(monoFamily, size: size).weight(weight)
                : .system(size: size, weight: weight, design: .monospaced)
    }

    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: 1)
    }
}
