// Draws the app icon. Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func draw(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: the body is about 80% of the canvas.
    let inset = size * 0.1
    let body = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let corner = body.width * 0.225
    NSColor(white: 0.10, alpha: 1).setFill()
    NSBezierPath(roundedRect: body, xRadius: corner, yRadius: corner).fill()

    let housingWidth = body.width * 0.36
    let housing = NSRect(
        x: body.midX - housingWidth / 2, y: body.minY + body.height * 0.08,
        width: housingWidth, height: body.height * 0.84
    )
    NSColor(white: 0.20, alpha: 1).setFill()
    NSBezierPath(roundedRect: housing, xRadius: housingWidth * 0.3, yRadius: housingWidth * 0.3).fill()

    let lamps: [(NSColor, Bool)] = [
        (NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1), true),
        (NSColor(red: 1.0, green: 0.70, blue: 0.0, alpha: 1), false),
        (NSColor(red: 0.20, green: 0.84, blue: 0.29, alpha: 1), false),
    ]
    let diameter = housingWidth * 0.68
    let gap = (housing.height - 3 * diameter) / 4
    for (index, lamp) in lamps.enumerated() {
        let y = housing.maxY - gap - diameter - CGFloat(index) * (diameter + gap)
        let rect = NSRect(x: housing.midX - diameter / 2, y: y, width: diameter, height: diameter)
        if lamp.1 {
            let shadow = NSShadow()
            shadow.shadowColor = lamp.0.withAlphaComponent(0.9)
            shadow.shadowBlurRadius = diameter * 0.35
            shadow.set()
        }
        lamp.0.withAlphaComponent(lamp.1 ? 1 : 0.28).setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSShadow().set()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try draw(pixels: points * scale).write(to: output.appendingPathComponent(name))
    }
}
