import AppKit
import DockDomain

@MainActor
public final class IconRepository {
    private struct CachedIcon {
        let image: NSImage
        let cost: Int
        var access: UInt64
    }

    private let capacity: Int
    private var icons: [URL: CachedIcon] = [:]
    private var cost = 0
    private var clock: UInt64 = 0
    private let workspace: NSWorkspace

    public convenience init() {
        self.init(capacity: 16 * 1_024 * 1_024, workspace: .shared)
    }

    init(capacity: Int, workspace: NSWorkspace = .shared) {
        self.capacity = max(0, capacity)
        self.workspace = workspace
    }

    public func image(for entry: AppEntry) -> NSImage {
        let url = canonicalApplicationURL(URL(fileURLWithPath: entry.bundlePath))
        clock &+= 1
        if var cached = icons[url] {
            cached.access = clock
            icons[url] = cached
            return copy(cached.image)
        }
        let source = workspace.icon(forFile: url.path)
        let image = rasterizedIcon(source)
        // 64pt의 1x/2x 파생 표현만 보관하여 고해상도 원본의 무제한 누적을 막는다.
        let imageCost = 64 * 64 * 4 + 128 * 128 * 4
        if imageCost <= capacity {
            while cost + imageCost > capacity,
                  let oldest = icons.min(by: { $0.value.access < $1.value.access }) {
                cost -= oldest.value.cost
                icons.removeValue(forKey: oldest.key)
            }
            icons[url] = CachedIcon(image: image, cost: imageCost, access: clock)
            cost += imageCost
        }
        return copy(image)
    }

    public func invalidate() {
        icons.removeAll(keepingCapacity: false)
        cost = 0
    }

    var cachedCost: Int { cost }
    var cachedCount: Int { icons.count }

    private func rasterizedIcon(_ source: NSImage) -> NSImage {
        let size = NSSize(width: 64, height: 64)
        let image = NSImage(size: size)
        for scale in [1, 2] {
            guard let representation = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 64 * scale,
                pixelsHigh: 64 * scale,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ), let context = NSGraphicsContext(bitmapImageRep: representation) else { continue }
            representation.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            source.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(representation)
        }
        image.isTemplate = false
        return image
    }

    private func copy(_ image: NSImage) -> NSImage {
        // 호출자가 표시 크기를 바꿔도 저장된 이미지나 시스템 공유 아이콘은 바뀌지 않는다.
        (image.copy() as? NSImage) ?? NSImage(size: image.size)
    }
}
