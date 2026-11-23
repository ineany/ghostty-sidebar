// Draws the app icon (Catppuccin Mocha) into a 1024x1024 PNG.
// usage: swift scripts/make-icon.swift <out.png>
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let size: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS icon grid: 824 pt rounded square centred in 1024.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(starting: color(0x1e1e2e), ending: color(0x11111b))!.draw(in: tilePath, angle: -90)
color(0x313244).setStroke()
tilePath.lineWidth = 6
tilePath.stroke()

// Sidebar strip on the left.
let strip = NSRect(x: 160, y: 160, width: 250, height: 704)
color(0x181825).setFill()
NSBezierPath(roundedRect: strip, xRadius: 40, yRadius: 40).fill()

// Rows: status dot + title bar. Second row is the current one (mauve marker).
let rows: [(UInt32, CGFloat)] = [(0xa6e3a1, 0.9), (0xfab387, 0.7), (0xa6e3a1, 0.8), (0x6c7086, 0.6)]
for (i, row) in rows.enumerated() {
    let y = 740 - CGFloat(i) * 150
    if i == 1 {
        color(0x313244).setFill()
        NSBezierPath(roundedRect: NSRect(x: 180, y: y - 45, width: 210, height: 90), xRadius: 18, yRadius: 18).fill()
        color(0xcba6f7).setFill()
        NSBezierPath(roundedRect: NSRect(x: 184, y: y - 28, width: 10, height: 56), xRadius: 5, yRadius: 5).fill()
    }
    color(row.0).setFill()
    NSBezierPath(ovalIn: NSRect(x: 212, y: y - 16, width: 32, height: 32)).fill()
    color(0xcdd6f4, 0.85).setFill()
    NSBezierPath(roundedRect: NSRect(x: 262, y: y - 9, width: 110 * row.1, height: 18), xRadius: 9, yRadius: 9).fill()
}

// Terminal area: prompt glyph and a cursor block.
let prompt = NSAttributedString(string: "❯", attributes: [
    .font: NSFont.monospacedSystemFont(ofSize: 300, weight: .heavy),
    .foregroundColor: color(0xcba6f7),
])
prompt.draw(at: NSPoint(x: 470, y: 380))
color(0xcdd6f4).setFill()
NSBezierPath(roundedRect: NSRect(x: 700, y: 430, width: 120, height: 200), xRadius: 14, yRadius: 14).fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode PNG")
}
try png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
