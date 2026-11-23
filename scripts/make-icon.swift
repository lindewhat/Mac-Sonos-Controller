// Draws the app icon and writes Resources/AppIcon.icns.
// Run: swift scripts/make-icon.swift   (only needed when the design changes; the .icns is committed)
import AppKit

func drawIcon(in ctx: CGContext, size s: CGFloat) {
    let u = s / 1024  // all coordinates below are on a 1024 grid
    ctx.saveGState()
    ctx.scaleBy(x: u, y: u)

    // Tile: standard macOS icon grid (824 pt tile inside 1024 pt canvas).
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor(red: 0.10, green: 0.14, blue: 0.24, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient (deep blue to teal).
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [NSColor(red: 0.16, green: 0.20, blue: 0.42, alpha: 1).cgColor,
                  NSColor(red: 0.05, green: 0.55, blue: 0.62, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
    // Gentle highlight on the top half.
    let hl = [NSColor.white.withAlphaComponent(0.16).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray
    let hlGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: hl, locations: [0, 1])!
    ctx.drawLinearGradient(hlGradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 520), options: [])
    ctx.restoreGState()

    // Speaker glyph in white; shifted left so glyph plus waves sit centred on the tile.
    ctx.translateBy(x: -55, y: 0)
    ctx.setFillColor(NSColor.white.cgColor)
    let speaker = CGMutablePath()
    speaker.move(to: CGPoint(x: 250, y: 600))
    speaker.addLine(to: CGPoint(x: 360, y: 600))
    speaker.addLine(to: CGPoint(x: 520, y: 740))
    speaker.addLine(to: CGPoint(x: 520, y: 284))
    speaker.addLine(to: CGPoint(x: 360, y: 424))
    speaker.addLine(to: CGPoint(x: 250, y: 424))
    speaker.closeSubpath()
    ctx.addPath(speaker)
    ctx.fillPath()

    // Sound waves: three arcs on the right.
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineCap(.round)
    ctx.setLineWidth(44)
    let centre = CGPoint(x: 520, y: 512)
    for (radius, alpha) in [(150.0, 1.0), (250.0, 0.85), (350.0, 0.7)] as [(CGFloat, CGFloat)] {
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        ctx.addArc(center: centre, radius: radius, startAngle: -.pi / 5, endAngle: .pi / 5, clockwise: false)
        ctx.strokePath()
    }
    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    drawIcon(in: gc.cgContext, size: CGFloat(size))
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
try? png(size: 1024).write(to: fm.temporaryDirectory.appendingPathComponent("AppIcon-preview.png"))
print("Wrote \(out.path) (status \(p.terminationStatus))")
