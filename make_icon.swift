// Generates AppIcon.icns (run: swift make_icon.swift .)
import AppKit
import Foundation

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func makeImage(size: Int) -> Data {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
        let inset = s * 0.055
        let body = rect.insetBy(dx: inset, dy: inset)
        let radius = body.width * 0.225

        let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        let gradient = NSGradient(colors: [
            NSColor(srgbRed: 0.30, green: 0.52, blue: 0.96, alpha: 1),
            NSColor(srgbRed: 0.10, green: 0.22, blue: 0.66, alpha: 1),
        ])!
        gradient.draw(in: path, angle: -90)

        // soft top highlight
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let shine = NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.0),
            NSColor.white.withAlphaComponent(0.16),
        ])!
        shine.draw(in: NSRect(x: body.minX, y: body.midY,
                              width: body.width, height: body.height * 0.6),
                   angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        if let symbol = NSImage(systemSymbolName: "duffle.bag",
                                accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(
                pointSize: s * 0.52, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(
                    paletteColors: [NSColor.white]))
            let drawn = symbol.withSymbolConfiguration(config) ?? symbol
            let target = drawn.size
            let origin = NSPoint(x: rect.midX - target.width / 2,
                                 y: rect.midY - target.height / 2)
            drawn.draw(in: NSRect(origin: origin, size: target))
        }
        return true
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size,
                               pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: s, height: s))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! makeImage(size: size).write(to: iconset.appendingPathComponent(name))
    }
}
print(iconset.path)
