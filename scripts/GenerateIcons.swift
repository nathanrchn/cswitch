import AppKit
import Foundation

/// Renders artwork only. It never starts Cswitch or accesses account data.
@main
enum GenerateIcons {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "CswitchIcons", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Provide an output directory."])
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let iconset = output.appendingPathComponent("Cswitch.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                try png(size: pixels) { bounds in CswitchIcon.drawAppIcon(in: bounds) }
                    .write(to: iconset.appendingPathComponent(filename))
            }
        }
        // A static artwork preview, independent of the app and its login state.
        try png(size: 512) { bounds in CswitchIcon.drawAppIcon(in: bounds) }
            .write(to: output.appendingPathComponent("Cswitch.png"))
        try png(size: 180) { bounds in
            NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1).setFill()
            bounds.fill()
            CswitchIcon.drawGlyph(in: NSRect(x: 40, y: 40, width: 100, height: 100), color: .white)
        }.write(to: output.appendingPathComponent("MenuBar.png"))
    }

    private static func png(size: Int, draw: (NSRect) -> Void) throws -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
        draw(NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "CswitchIcons", code: 2)
        }
        return data
    }
}
