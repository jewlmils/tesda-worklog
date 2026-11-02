// Draws the app icon: a simple white octopus holding one pen, on a TESDA-blue rounded square.
//
//   swift assets/make_icon.swift            (install.sh runs this if AppIcon.icns is missing)
//
// Writes assets/AppIcon-1024.png and assets/AppIcon.icns. Coordinates are on a 1024×1024
// canvas with y pointing UP (AppKit), following Apple's icon grid (824×824 body).

import AppKit

let assets = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let white = NSColor.white
let navy = rgb(0x0B2E6B)

func tentacle(_ points: [(CGFloat, CGFloat)], width: CGFloat) {
    // A smooth stroke through the points (Catmull-Rom → Bézier), round ends.
    let p = NSBezierPath()
    p.lineWidth = width
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    let pts = points.map { NSPoint(x: $0.0, y: $0.1) }
    p.move(to: pts[0])
    for i in 0..<(pts.count - 1) {
        let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
        let c1 = NSPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let c2 = NSPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        p.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
    }
    white.setStroke()
    p.stroke()
}

func drawPen() {
    // A pen tilted 20°, cap up-right, nib down-left as if writing.
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: 775, yBy: 520)
    t.rotate(byDegrees: -20)
    t.concat()
    // body (centered on origin, tip pointing to -y)
    let body = NSBezierPath(roundedRect: NSRect(x: -30, y: -120, width: 60, height: 300), xRadius: 26, yRadius: 26)
    rgb(0xFFC21A).setFill(); body.fill()
    let cap = NSBezierPath(roundedRect: NSRect(x: -30, y: 95, width: 60, height: 85), xRadius: 26, yRadius: 26)
    rgb(0xE59A00).setFill(); cap.fill()
    let clip = NSBezierPath(roundedRect: NSRect(x: 18, y: 40, width: 14, height: 120), xRadius: 7, yRadius: 7)
    rgb(0xC98200).setFill(); clip.fill()
    // nib
    let nib = NSBezierPath()
    nib.move(to: NSPoint(x: -30, y: -105)); nib.line(to: NSPoint(x: 30, y: -105)); nib.line(to: NSPoint(x: 0, y: -195)); nib.close()
    navy.setFill(); nib.fill()
    NSGraphicsContext.restoreGraphicsState()
}

func drawIcon() {
    // Background: rounded square with a blue gradient.
    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)
    NSGradient(starting: rgb(0x3D86F0), ending: rgb(0x0B3F94))!.draw(in: body, angle: -90)

    // Octopus, drawn as one layer so it gets one soft shadow.
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: NSColor(white: 0, alpha: 0.28).cgColor)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

    // Tentacles (behind the head). Five curl below; the sixth reaches out to hold the pen.
    let w: CGFloat = 54
    tentacle([(405, 520), (360, 420), (300, 340), (262, 270), (300, 230), (338, 262)], width: w)
    tentacle([(450, 500), (430, 390), (405, 300), (398, 230), (440, 205), (462, 245)], width: w)
    tentacle([(512, 495), (515, 380), (520, 290), (535, 220), (580, 212), (585, 255)], width: w)
    tentacle([(570, 500), (590, 400), (600, 320), (612, 250), (655, 232), (668, 270)], width: w)
    tentacle([(380, 560), (310, 520), (245, 470), (210, 410), (240, 370), (275, 395)], width: w)

    // Head: a soft dome.
    let head = NSBezierPath(ovalIn: NSRect(x: 330, y: 455, width: 364, height: 400))
    white.setFill(); head.fill()

    ctx.endTransparencyLayer()
    ctx.restoreGState()

    drawPen()
    // The sixth tentacle reaches out and wraps around the pen.
    tentacle([(640, 562), (690, 552), (735, 536), (780, 518), (822, 500), (836, 462), (810, 446)], width: w)

    // Face.
    for x in [440.0, 584.0] as [CGFloat] {
        navy.setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 28, y: 610, width: 56, height: 74)).fill()
        white.setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 4, y: 650, width: 20, height: 20)).fill()
    }
    let smile = NSBezierPath()
    smile.move(to: NSPoint(x: 482, y: 568))
    smile.curve(to: NSPoint(x: 542, y: 568), controlPoint1: NSPoint(x: 495, y: 540), controlPoint2: NSPoint(x: 529, y: 540))
    smile.lineWidth = 12
    smile.lineCapStyle = .round
    navy.setStroke(); smile.stroke()
}

func render(_ size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    let s = CGFloat(size) / 1024
    let t = NSAffineTransform(); t.scale(by: s); t.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, _ url: URL) {
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

write(render(1024), assets.appendingPathComponent("AppIcon-1024.png"))
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    write(render(base), iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    write(render(base * 2), iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote assets/AppIcon.icns and assets/AppIcon-1024.png" : "iconutil failed")
