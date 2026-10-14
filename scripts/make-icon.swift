// Draws the app icon and writes packaging/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (needs iconutil, part of macOS)
import AppKit

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    // Background: macOS icon grid (824 pt tile, 100 pt margin), deep blue to teal.
    let tile = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(red: 0.05, green: 0.16, blue: 0.36, alpha: 1),
               ending: NSColor(red: 0.00, green: 0.55, blue: 0.62, alpha: 1))!.draw(in: tile, angle: 60)

    // Watch: strap, case and face.
    NSColor(white: 1, alpha: 0.35).setFill()
    NSBezierPath(roundedRect: r(400, 170, 224, 684), xRadius: 60 * s, yRadius: 60 * s).fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: r(312, 312, 400, 400), xRadius: 110 * s, yRadius: 110 * s).fill()
    NSColor(red: 0.06, green: 0.18, blue: 0.34, alpha: 1).setFill()
    NSBezierPath(roundedRect: r(352, 352, 320, 320), xRadius: 80 * s, yRadius: 80 * s).fill()

    // Sync arrows on the face.
    let c = NSPoint(x: 512 * s, y: 512 * s), radius = 92 * s
    NSColor(red: 0.20, green: 0.85, blue: 0.80, alpha: 1).set()
    for start in [CGFloat(20), 200] {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: c, radius: radius, startAngle: start, endAngle: start + 130)
        arc.lineWidth = 34 * s
        arc.lineCapStyle = .round
        arc.stroke()
        // Arrowhead at the end of the arc, pointing along the direction of travel.
        let a = (start + 130) * .pi / 180
        let tip = NSPoint(x: c.x + radius * cos(a), y: c.y + radius * sin(a))
        let dir = NSPoint(x: -sin(a), y: cos(a)), out = NSPoint(x: cos(a), y: sin(a))
        let head = NSBezierPath()
        head.move(to: NSPoint(x: tip.x + dir.x * 46 * s, y: tip.y + dir.y * 46 * s))
        head.line(to: NSPoint(x: tip.x + out.x * 44 * s, y: tip.y + out.y * 44 * s))
        head.line(to: NSPoint(x: tip.x - out.x * 44 * s, y: tip.y - out.y * 44 * s))
        head.close()
        head.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try render(CGFloat(base * scale)).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
let out = root.appendingPathComponent("packaging/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
