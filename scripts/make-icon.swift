// Renders the OpenSpell app icon into an .iconset folder (macOS), or into a single PNG (iOS).
// Usage: swift scripts/make-icon.swift <output.iconset | AppIcon.png>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")

/// `fullBleed` is the iOS variant: iOS rounds the corners itself and rejects transparency,
/// so the tile fills an opaque square with no shadow.
func render(size: CGFloat, fullBleed: Bool = false) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: fullBleed ? 3 : 4, hasAlpha: !fullBleed, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    if fullBleed {
        let zoom = NSAffineTransform()
        zoom.scale(by: 1024 / 824)
        zoom.translateX(by: -100 * s, yBy: -100 * s)
        zoom.concat()
    }

    // macOS icon grid: 824pt rounded square centred in 1024.
    let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = fullBleed ? NSBezierPath(rect: rect) : NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)

    if !fullBleed {
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 20 * s
        shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
        shadow.set()
        NSColor.white.setFill()
        path.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.23, green: 0.47, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.55, green: 0.33, blue: 0.95, alpha: 1),
    ])!
    gradient.draw(in: path, angle: -60)

    // "Aa" glyphs.
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 380 * s, weight: .heavy),
        .foregroundColor: NSColor.white,
        .paragraphStyle: para,
    ]
    NSAttributedString(string: "Aa", attributes: attrs)
        .draw(in: NSRect(x: rect.minX, y: rect.minY + 300 * s, width: rect.width, height: 460 * s))

    // Check mark swoosh underneath.
    let check = NSBezierPath()
    check.lineWidth = 64 * s
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    check.move(to: NSPoint(x: 330 * s, y: 300 * s))
    check.line(to: NSPoint(x: 450 * s, y: 200 * s))
    check.line(to: NSPoint(x: 700 * s, y: 380 * s))
    NSColor(calibratedRed: 0.45, green: 1.0, blue: 0.6, alpha: 1).setStroke()
    check.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

if out.pathExtension == "png" {
    try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    try render(size: 1024, fullBleed: true).write(to: out)
} else {
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = CGFloat(base * scale)
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try render(size: px).write(to: out.appending(path: name))
        }
    }
}
print("Wrote \(out.path)")
