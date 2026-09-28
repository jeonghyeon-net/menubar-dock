import AppKit
import Testing
@testable import MenuBarDock

@Suite
@MainActor
struct SwitcherMaterialTests {
    @Test(arguments: [NSSize(width: 220, height: 116), NSSize(width: 728, height: 116)])
    func materialMaskKeepsAllFourCornersTransparent(size: NSSize) throws {
        let image = SwitcherController.roundedMaterialMask(size: size, radius: 18)
        var rect = NSRect(origin: .zero, size: size)
        let cgImage = try #require(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let pixels = NSBitmapImageRep(cgImage: cgImage)
        let maxX = pixels.pixelsWide - 1
        let maxY = pixels.pixelsHigh - 1
        for (x, y) in [(0, 0), (maxX, 0), (0, maxY), (maxX, maxY)] {
            #expect(try #require(pixels.colorAt(x: x, y: y)).alphaComponent == 0)
        }
        #expect(try #require(pixels.colorAt(x: maxX / 2, y: maxY / 2)).alphaComponent == 1)
        #expect(try #require(pixels.colorAt(x: maxX / 2, y: 1)).alphaComponent == 1)
    }
}
