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
    static let maxSourceFrames = 5000
    public static let extensions = ["gif", "png", "jpg", "jpeg", "webp", "bmp", "heic"]

    public struct Frames {
        public let images: [CGImage]   // already 320x172
        public let delayMs: Int
    }

    /// Frames that will be sent (after thinning out fast GIFs).
    public static func frameCount(_ url: URL) -> Int {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 1 }
        let n = CGImageSourceGetCount(src)
        guard n > 0 else { return 1 }
        return S98.pickFrames((0..<n).map { delay(src, $0) }).indices.count
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
        guard count > 0, count <= maxSourceFrames else { throw MediaError.unreadable(url.lastPathComponent) }
        // the keyboard can't show a frame faster than it draws it: thin out fast GIFs to keep their speed
        let pick = S98.pickFrames((0..<count).map { delay(src, $0) }, maxFrames: maxFrames)
        let indices = pick.indices
        let ms = min(65535, pick.ms)
        // GIF frames can be partial: composite each onto the previous one like a browser does
        var canvas: CGImage?
        var out = [CGImage]()
        var rendered = [Int: CGImage]()
        for i in 0..<(indices.last! + 1) {
            guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            canvas = composite(img, over: canvas)
            if indices.contains(i), let c = canvas { rendered[i] = render(c, fit: fit) }
        }
        for i in indices { if let r = rendered[i] { out.append(r) } }   // a frame may be picked twice
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
        // straight to RGB565 big-endian, same formula as S98.rgb565be (no per-pixel arrays)
        var out = [UInt8](repeating: 0, count: W * H * 2)
        var j = 0
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let v = UInt16(rgba[i] >> 3) << 11 | UInt16(rgba[i + 1] >> 2) << 5 | UInt16(rgba[i + 2] >> 3)
            out[j] = UInt8(v >> 8)
            out[j + 1] = UInt8(v & 0xFF)
            j += 2
        }
        return out
    }

    public static func estimateSeconds(_ frames: Int) -> Double { Double(frames) * secondsPerFrame }
}
