// 앱 아이콘은 외부 에셋 없이 벡터 도형으로 생성해 모든 해상도에서 선명하게 유지한다.
import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { exit(1) }
let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let bounds = NSRect(x: 52, y: 52, width: 920, height: 920)
        let background = NSBezierPath(roundedRect: bounds, xRadius: 210, yRadius: 210)
        NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.23, alpha: 1).setFill()
        background.fill()
        NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
        background.lineWidth = 3
        background.stroke()
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 148, y: 640, width: 728, height: 96), xRadius: 29, yRadius: 29).fill()
        let colors: [NSColor] = [
            NSColor(calibratedRed: 0.31, green: 0.80, blue: 0.90, alpha: 1),
            NSColor(calibratedRed: 0.52, green: 0.59, blue: 1, alpha: 1),
            NSColor(calibratedRed: 0.99, green: 0.72, blue: 0.43, alpha: 1),
        ]
        for (index, color) in colors.enumerated() {
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 156 + index * 244, y: 298, width: 224, height: 224), xRadius: 54, yRadius: 54).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        if let png = bitmap.representation(using: .png, properties: [:]) {
            let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
            try png.write(to: directory.appendingPathComponent(name))
        }
    }
}
