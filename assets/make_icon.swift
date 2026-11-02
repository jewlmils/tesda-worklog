// Draws TESDA Worklog's icons from one octopus shape:
//   - AppIcon.icns + AppIcon-1024.png : white octopus on a solid blue rounded square (Dock, Finder)
//   - MenuIcon.png / MenuIcon@2x.png  : black octopus "template" image for the menu bar
//                                       (macOS recolours it for light/dark menu bars)
//
//   swift assets/make_icon.swift      (install.sh runs this if the files are missing)
//
// Coordinates: 1024×1024 canvas, y pointing UP (AppKit), Apple's icon grid (824×824 body).

import AppKit

let assets = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let blue = NSColor(srgbRed: 0x1A / 255.0, green: 0x56 / 255.0, blue: 0xC6 / 255.0, alpha: 1)

/// The octopus: a dome head, a wider "skirt", and six short tentacles with round ends.
/// Drawn in `color`. Its bounding box is about x 173…851, y 200…820 on the 1024 canvas.
func drawOctopus(_ color: NSColor) {
    color.setFill()
    color.setStroke()
    let dy: CGFloat = 30   // vertical centring on the canvas
    NSBezierPath(ovalIn: NSRect(x: 322, y: 390 + dy, width: 380, height: 400)).fill()   // head
    NSBezierPath(ovalIn: NSRect(x: 282, y: 352 + dy, width: 460, height: 170)).fill()   // skirt

    let tentacles: [[(CGFloat, CGFloat)]] = [
        [(340, 450), (272, 422), (228, 380), (214, 326)],    // outer left: out, then down
        [(392, 400), (350, 345), (326, 290), (330, 236)],
        [(470, 380), (458, 312), (446, 258), (418, 220)],    // middle pair curl apart
        [(554, 380), (566, 312), (578, 258), (606, 220)],
        [(632, 400), (674, 345), (698, 290), (694, 236)],
        [(684, 450), (752, 422), (796, 380), (810, 326)],    // outer right
    ]
    for pts in tentacles {
        let p = NSBezierPath()
        p.lineWidth = 86
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        let q = pts.map { NSPoint(x: $0.0, y: $0.1 + dy) }
        p.move(to: q[0])
        for i in 0..<(q.count - 1) {                         // smooth curve through the points
            let p0 = q[max(i - 1, 0)], p1 = q[i], p2 = q[i + 1], p3 = q[min(i + 2, q.count - 1)]
            p.curve(to: p2, controlPoint1: NSPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                    controlPoint2: NSPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        p.stroke()
    }
}

func drawAppIcon() {
    blue.setFill()
    NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186).fill()
    // Shrink the octopus a little so it sits comfortably inside the square.
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: 512, yBy: 512); t.scale(by: 0.86); t.translateX(by: -512, yBy: -512)
    t.concat()
    drawOctopus(.white)
    NSGraphicsContext.restoreGraphicsState()
}

/// Menu bar glyph: the octopus alone, cropped to its own bounds.
func drawMenuGlyph(_ w: CGFloat, _ h: CGFloat) {
    let box = NSRect(x: 170, y: 195, width: 684, height: 630)   // octopus bounds incl. stroke ends
    let s = min(w / box.width, h / box.height)
    let t = NSAffineTransform()
    t.translateX(by: (w - box.width * s) / 2, yBy: (h - box.height * s) / 2)
    t.scale(by: s)
    t.translateX(by: -box.minX, yBy: -box.minY)
    t.concat()
    drawOctopus(.black)
}

func render(_ w: Int, _ h: Int, _ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func appIcon(_ size: Int) -> NSBitmapImageRep {
    render(size, size) {
        let t = NSAffineTransform(); t.scale(by: CGFloat(size) / 1024); t.concat()
        drawAppIcon()
    }
}

func write(_ rep: NSBitmapImageRep, _ name: String, in dir: URL = assets) {
    try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
}

write(appIcon(1024), "AppIcon-1024.png")
// Menu bar: 20×18 pt, plus @2x for Retina.
write(render(20, 18) { drawMenuGlyph(20, 18) }, "MenuIcon.png")
let retina = render(40, 36) { drawMenuGlyph(40, 36) }
write(retina, "MenuIcon@2x.png")

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    write(appIcon(base), "icon_\(base)x\(base).png", in: iconset)
    write(appIcon(base * 2), "icon_\(base)x\(base)@2x.png", in: iconset)
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote AppIcon.icns, AppIcon-1024.png, MenuIcon.png, MenuIcon@2x.png" : "iconutil failed")
