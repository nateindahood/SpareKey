import CoreGraphics
import Foundation
import ImageIO

public enum Fit: String, CaseIterable, Codable, Identifiable {
    case cover, contain, stretch
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .cover: return "Fill (crop)"
        case .contain: return "Fit (letterbox)"
        case .stretch: return "Stretch"
        }
    }
}

public enum MediaError: Error, LocalizedError {
    case unreadable(String)
    public var errorDescription: String? {
        if case .unreadable(let s) = self { return "Couldn't read \(s)" }
        return nil
    }
}

/// GIFs and images -> 320x172 frames. Mirrors src/sparekey/media.py.
public enum Media {
    public static let secondsPerFrame = 12.7
    public static let extensions = ["gif", "png", "jpg", "jpeg", "webp", "bmp", "heic"]

    public struct Frames {
        public let images: [CGImage]   // already 320x172
        public let delayMs: Int
    }

    public static func frameCount(_ url: URL) -> Int {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 1 }
        return min(S98.maxFrames, max(1, CGImageSourceGetCount(src)))
    }

    static func delay(_ src: CGImageSource, _ i: Int) -> Int {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 100 }
        let d = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        let ms = Int((d * 1000).rounded())
        return ms > 0 ? ms : 100
    }

    public static func load(_ url: URL, fit: Fit = .cover, maxFrames: Int = S98.maxFrames) throws -> Frames {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw MediaError.unreadable(url.lastPathComponent) }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { throw MediaError.unreadable(url.lastPathComponent) }
        var indices = Array(0..<count)
        var durations = indices.map { delay(src, $0) }
        if count > maxFrames {   // keep playback speed: merge the skipped frames' time
            let step = Double(count) / Double(maxFrames)
            let idx = (0..<maxFrames).map { Int(Double($0) * step) }
            durations = idx.enumerated().map { (n, start) in
                let end = n + 1 < idx.count ? idx[n + 1] : count
                return durations[start..<end].reduce(0, +)
            }
            indices = idx
        }
        let ms = max(10, min(65535, Int((Double(durations.reduce(0, +)) / Double(durations.count)).rounded())))
        // GIF frames can be partial: composite each onto the previous one like a browser does
        var canvas: CGImage?
        var out = [CGImage]()
        let wanted = Set(indices)
        for i in 0..<(indices.last! + 1) {
            guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            canvas = composite(img, over: canvas)
            if wanted.contains(i), let c = canvas { out.append(render(c, fit: fit)) }
        }
        guard !out.isEmpty else { throw MediaError.unreadable(url.lastPathComponent) }
        return Frames(images: out, delayMs: ms)
    }

    static func composite(_ img: CGImage, over base: CGImage?) -> CGImage {
        guard let base = base, base.width == img.width, base.height == img.height,
              let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        let r = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        ctx.draw(base, in: r)
        ctx.draw(img, in: r)
        return ctx.makeImage() ?? img
    }

    public static func render(_ img: CGImage, fit: Fit) -> CGImage {
        let W = S98.screenWidth, H = S98.screenHeight
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.interpolationQuality = .high
        let iw = Double(img.width), ih = Double(img.height)
        var rect = CGRect(x: 0, y: 0, width: W, height: H)
        switch fit {
        case .stretch: break
        case .cover, .contain:
            let s = fit == .cover ? max(Double(W) / iw, Double(H) / ih) : min(Double(W) / iw, Double(H) / ih)
            let w = iw * s, h = ih * s
            rect = CGRect(x: (Double(W) - w) / 2, y: (Double(H) - h) / 2, width: w, height: h)
        }
        ctx.draw(img, in: rect)
        return ctx.makeImage()!
    }

    /// 320x172 CGImage -> RGB565 big-endian bytes, row-major from the top.
    public static func encode(_ img: CGImage) -> [UInt8] {
        let W = S98.screenWidth, H = S98.screenHeight
        var rgba = [UInt8](repeating: 0, count: W * H * 4)
        rgba.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        }
        var rgb = [UInt8]()
        rgb.reserveCapacity(W * H * 3)
        for i in stride(from: 0, to: rgba.count, by: 4) { rgb += [rgba[i], rgba[i + 1], rgba[i + 2]] }
        return S98.rgb565be(rgb)
    }

    public static func estimateSeconds(_ frames: Int) -> Double { Double(frames) * secondsPerFrame }
}
