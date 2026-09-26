#!/usr/bin/env swift
// Renders the RowHouse app icon and writes Packaging/AppIcon.icns.
//   swift scripts/generate-icon.swift
import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha])!
}

func render(size: Int) -> CGImage {
    let s = CGFloat(size) / 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)

    // Squircle background with a soft shadow, following the macOS icon grid (824pt body on 1024).
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.28))
    ctx.addPath(squircle)
    ctx.setFillColor(color(0x5B5FEF))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(0x3F8CFF), color(0x6A4CF5), color(0x9B45F2)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 150, y: 924), end: CGPoint(x: 874, y: 100), options: [])
    // Gentle top highlight.
    let shine = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    // House: roof + body, white with a subtle shadow.
    let house = CGMutablePath()
    let left: CGFloat = 268, right: CGFloat = 756, eave: CGFloat = 548, apex: CGFloat = 780, bottom: CGFloat = 232
    house.move(to: CGPoint(x: 512, y: apex))
    house.addLine(to: CGPoint(x: right + 34, y: eave))
    house.addLine(to: CGPoint(x: right, y: eave))
    house.addLine(to: CGPoint(x: right, y: bottom + 36))
    house.addQuadCurve(to: CGPoint(x: right - 36, y: bottom), control: CGPoint(x: right, y: bottom))
    house.addLine(to: CGPoint(x: left + 36, y: bottom))
    house.addQuadCurve(to: CGPoint(x: left, y: bottom + 36), control: CGPoint(x: left, y: bottom))
    house.addLine(to: CGPoint(x: left, y: eave))
    house.addLine(to: CGPoint(x: left - 34, y: eave))
    house.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x1B0B5C, 0.35))
    ctx.addPath(house)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(28)
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.drawPath(using: .fillStroke)
    ctx.restoreGState()

    // A 3 × 3 grid of table cells for windows: a header row plus coloured rows.
    let cols = 3, rows = 3
    let gridLeft = left + 44, gridRight = right - 44, gridTop = eave - 26, gridBottom = bottom + 44
    let gap: CGFloat = 16
    let cellW = (gridRight - gridLeft - gap * CGFloat(cols - 1)) / CGFloat(cols)
    let cellH = (gridTop - gridBottom - gap * CGFloat(rows - 1)) / CGFloat(rows)
    let palette: [[UInt32]] = [
        [0x3F4A7A, 0x3F4A7A, 0x3F4A7A],
        [0x2D7FF9, 0x20C9A6, 0xFCB400],
        [0xF82B60, 0x8B46FF, 0x18BFFF],
    ]
    for r in 0..<rows {
        for c in 0..<cols {
            let x = gridLeft + CGFloat(c) * (cellW + gap)
            let y = gridTop - CGFloat(r + 1) * cellH - CGFloat(r) * gap
            let rect = CGRect(x: x, y: y, width: cellW, height: cellH)
            let alpha: CGFloat = r == 0 ? 0.9 : 1
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 16, cornerHeight: 16, transform: nil))
            ctx.setFillColor(color(palette[r][c], alpha))
            ctx.fillPath()
            if r > 0 {
                // A lighter "text line" inside each cell.
                let line = CGRect(x: x + 18, y: y + cellH / 2 - 7, width: cellW * (c == 1 ? 0.45 : 0.6), height: 14)
                ctx.addPath(CGPath(roundedRect: line, cornerWidth: 7, cornerHeight: 7, transform: nil))
                ctx.setFillColor(color(0xFFFFFF, 0.55))
                ctx.fillPath()
            }
        }
    }
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try writePNG(render(size: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try writePNG(render(size: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let packaging = root.appendingPathComponent("Packaging", isDirectory: true)
try writePNG(render(size: 256), to: root.appendingPathComponent(".github/assets/icon.png"))
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", packaging.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "Wrote Packaging/AppIcon.icns" : "iconutil failed")
