import AppKit
import Foundation

func fail(_ message: String) -> Never {
    fputs("\(message)\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("Usage: swift build-macos-icon.swift <source.png> <output.iconset>")
}
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let source = NSImage(contentsOf: sourceURL),
      let sourceData = try? Data(contentsOf: sourceURL),
      let sourcePixels = NSBitmapImageRep(data: sourceData),
      sourcePixels.pixelsWide == sourcePixels.pixelsHigh else {
    fail("The icon source must be a readable square image.")
}
guard !FileManager.default.fileExists(atPath: outputURL.path) else {
    fail("The output iconset already exists; choose a new path.")
}
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: false)

// The source tile fills about 97% of its canvas. An 848/1024 drawing area
// gives it the same ~824/1024 solid footprint as macOS system app icons.
let artworkScale = 848.0 / 1024.0
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fail("Could not create the \(pixels)-pixel icon canvas.")
        }
        bitmap.size = NSSize(width: pixels, height: pixels)
        let side = Double(pixels) * artworkScale
        let inset = (Double(pixels) - side) / 2
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        source.draw(in: NSRect(x: inset, y: inset, width: side, height: side),
                    from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            fail("Could not encode the \(pixels)-pixel icon.")
        }
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(points)x\(points)\(suffix).png"
        try data.write(to: outputURL.appendingPathComponent(name))
    }
}
