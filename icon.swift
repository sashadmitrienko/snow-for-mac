// Рисует иконку Snow.app: зимнее небо, сугроб и снежинка. Использование: swift icon.swift <папка.iconset>
import Cocoa

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Snow.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let box = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225)

    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.38, alpha: 1),
                        NSColor(calibratedRed: 0.28, green: 0.47, blue: 0.80, alpha: 1)])?
        .draw(in: box, angle: 90)

    // сугроб
    let drift = NSBezierPath()
    drift.move(to: NSPoint(x: box.minX, y: box.minY))
    drift.line(to: NSPoint(x: box.minX, y: box.minY + box.height * 0.22))
    drift.curve(to: NSPoint(x: box.maxX, y: box.minY + box.height * 0.18),
                controlPoint1: NSPoint(x: box.minX + box.width * 0.35, y: box.minY + box.height * 0.36),
                controlPoint2: NSPoint(x: box.minX + box.width * 0.65, y: box.minY + box.height * 0.08))
    drift.line(to: NSPoint(x: box.maxX, y: box.minY))
    drift.close()
    NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
    drift.fill()

    // мелкие снежинки
    NSColor(calibratedWhite: 1, alpha: 0.85).setFill()
    let dots: [(CGFloat, CGFloat, CGFloat)] = [(0.22, 0.78, 0.022), (0.78, 0.82, 0.018), (0.30, 0.45, 0.016),
                                               (0.72, 0.42, 0.02), (0.15, 0.6, 0.014), (0.86, 0.62, 0.015)]
    for (x, y, r) in dots {
        let rr = r * box.width
        NSBezierPath(ovalIn: NSRect(x: box.minX + x * box.width - rr, y: box.minY + y * box.height - rr,
                                    width: rr * 2, height: rr * 2)).fill()
    }
    NSGraphicsContext.current?.restoreGraphicsState()

    // большая снежинка
    let c = NSPoint(x: box.midX, y: box.minY + box.height * 0.6)
    let R = box.width * 0.24
    let flake = NSBezierPath()
    flake.lineWidth = max(1, box.width * 0.035)
    flake.lineCapStyle = .round
    for k in 0..<6 {
        let a = CGFloat(k) * .pi / 3 + .pi / 2
        let tip = NSPoint(x: c.x + cos(a) * R, y: c.y + sin(a) * R)
        flake.move(to: c); flake.line(to: tip)
        for (f, len) in [(0.55, 0.32), (0.8, 0.22)] as [(CGFloat, CGFloat)] {
            let p = NSPoint(x: c.x + cos(a) * R * f, y: c.y + sin(a) * R * f)
            for side in [-1.0, 1.0] as [CGFloat] {
                let b = a + side * .pi / 4
                flake.move(to: p)
                flake.line(to: NSPoint(x: p.x + cos(b) * R * len, y: p.y + sin(b) * R * len))
            }
        }
    }
    NSColor.white.setStroke()
    flake.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        if let d = render(base * scale) {
            try? d.write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
        }
    }
}
