// 해상도별 벡터 렌더링으로 작은 아이콘의 윤곽과 투명한 모서리를 유지한다.
import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { exit(1) }
let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func roundedRectangle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func fillGradient(_ path: CGPath, colors: [CGColor], from: CGPoint, to: CGPoint, in context: CGContext) {
    guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil) else { return }
    context.saveGState()
    context.addPath(path)
    context.clip(using: .evenOdd)
    context.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

func drawIcon(in context: CGContext) {
    let tile = roundedRectangle(CGRect(x: 100, y: 100, width: 824, height: 824), radius: 184)
    // 정적 ICNS에는 재질이 자동으로 입혀지지 않으므로 흰 타일의 음영도 원본에 그린다.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -5), blur: 10, color: color(0, 0, 0, alpha: 0.18))
    context.setFillColor(color(0.98, 0.98, 0.98))
    context.addPath(tile)
    context.fillPath()
    context.restoreGState()
    fillGradient(tile, colors: [color(1, 1, 1), color(0.99, 0.99, 0.995), color(0.93, 0.935, 0.945)],
                 from: CGPoint(x: 380, y: 924), to: CGPoint(x: 644, y: 100), in: context)
    context.addPath(tile)
    context.setStrokeColor(color(0.74, 0.75, 0.77, alpha: 0.6))
    context.setLineWidth(1.5)
    context.strokePath()
    context.addPath(roundedRectangle(CGRect(x: 102, y: 103, width: 820, height: 819), radius: 182))
    context.setStrokeColor(color(1, 1, 1, alpha: 0.85))
    context.setLineWidth(2)
    context.strokePath()

    // 하나의 창 윤곽에서 메뉴 막대의 앱 세 칸과 본문을 뚫어 단일 심볼로 구성한다.
    let symbol = CGMutablePath()
    symbol.addPath(roundedRectangle(CGRect(x: 222, y: 292, width: 580, height: 444), radius: 65))
    symbol.addPath(roundedRectangle(CGRect(x: 260, y: 331, width: 504, height: 265), radius: 28))
    for x in [272, 366, 460] {
        symbol.addPath(roundedRectangle(CGRect(x: x, y: 631, width: 60, height: 60), radius: 17))
    }
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -8), blur: 12, color: color(0.10, 0.12, 0.17, alpha: 0.22))
    context.addPath(symbol)
    context.setFillColor(color(0.08, 0.09, 0.11))
    context.fillPath(using: .evenOdd)
    context.restoreGState()
    fillGradient(symbol, colors: [color(0.38, 0.40, 0.45), color(0.23, 0.25, 0.30), color(0.12, 0.13, 0.17), color(0.055, 0.065, 0.085)],
                 from: CGPoint(x: 430, y: 736), to: CGPoint(x: 574, y: 292), in: context)

    // 얇은 상단 반사와 어두운 테두리로 작은 크기에서도 과하지 않은 금속 입체감을 만든다.
    context.addPath(symbol)
    context.setStrokeColor(color(0.07, 0.08, 0.11, alpha: 0.85))
    context.setLineWidth(3)
    context.strokePath()
    context.saveGState()
    context.addPath(symbol)
    context.clip(using: .evenOdd)
    context.translateBy(x: 0, y: -3)
    context.addPath(symbol)
    context.setStrokeColor(color(0.93, 0.95, 1, alpha: 0.48))
    context.setLineWidth(2)
    context.strokePath()
    context.restoreGState()
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        drawIcon(in: context.cgContext)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
            try png.write(to: directory.appendingPathComponent(name))
        }
    }
}
