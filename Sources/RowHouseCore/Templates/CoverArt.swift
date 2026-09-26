import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generates soft abstract cover images for template records, so galleries and kanban cards look
/// finished without bundling stock photos.
public enum CoverArt {
    public static func jpeg(seed: Int, width: Int = 800, height: Int = 500) -> Data? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        var rng = SplitMix(seed: UInt64(truncatingIfNeeded: seed &* 7919 &+ 17))
        let palettes: [[(Double, Double, Double)]] = [
            [(0.36, 0.55, 0.98), (0.55, 0.36, 0.96), (0.98, 0.62, 0.78)],
            [(0.13, 0.72, 0.64), (0.42, 0.85, 0.52), (0.98, 0.88, 0.45)],
            [(0.98, 0.55, 0.33), (0.96, 0.33, 0.45), (0.55, 0.30, 0.78)],
            [(0.20, 0.35, 0.60), (0.25, 0.62, 0.86), (0.72, 0.90, 0.98)],
            [(0.95, 0.76, 0.32), (0.93, 0.47, 0.30), (0.62, 0.22, 0.36)],
            [(0.44, 0.33, 0.80), (0.30, 0.62, 0.95), (0.40, 0.90, 0.80)],
        ]
        let palette = palettes[abs(seed) % palettes.count]
        func color(_ c: (Double, Double, Double), _ a: Double = 1) -> CGColor {
            CGColor(colorSpace: space, components: [c.0, c.1, c.2, a])!
        }
        let gradient = CGGradient(colorsSpace: space, colors: [color(palette[0]), color(palette[1])] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: width, y: height), options: [])

        for i in 0..<7 {
            let r = Double(height) * (0.25 + rng.next() * 0.55)
            let x = rng.next() * Double(width)
            let y = rng.next() * Double(height)
            let c = palette[(i + 1) % palette.count]
            let blob = CGGradient(colorsSpace: space, colors: [color(c, 0.55), color(c, 0)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(blob, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
        }
        ctx.setStrokeColor(color((1, 1, 1), 0.18))
        ctx.setLineWidth(2)
        for i in 0..<5 {
            let y = Double(height) * (0.2 + Double(i) * 0.15) + rng.next() * 20
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addCurve(to: CGPoint(x: Double(width), y: y + (rng.next() - 0.5) * 80),
                         control1: CGPoint(x: Double(width) * 0.3, y: y + (rng.next() - 0.5) * 140),
                         control2: CGPoint(x: Double(width) * 0.7, y: y + (rng.next() - 0.5) * 140))
            ctx.strokePath()
        }
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
    }
}
