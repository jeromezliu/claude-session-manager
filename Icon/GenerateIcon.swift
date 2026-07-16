import AppKit
import CoreGraphics
import Foundation

// Renders the "F1" app icon (dark squircle, two cascaded terminal windows with a
// coral prompt, and a coral spark) to a full AppIcon.iconset. Pure CoreGraphics
// so it needs no external tooling. Usage: swift GenerateIcon.swift [outDir]

let sp = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: String, _ a: CGFloat = 1) -> CGColor {
    var h = hex; if h.hasPrefix("#") { h.removeFirst() }
    let v = UInt32(h, radix: 16) ?? 0
    return CGColor(colorSpace: sp, components: [
        CGFloat((v >> 16) & 0xff) / 255,
        CGFloat((v >> 8) & 0xff) / 255,
        CGFloat(v & 0xff) / 255, a
    ])!
}

func rr(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// Map the 200-unit design space (used in the preview) into the 1024 canvas,
// giving a ~10% transparent margin around the squircle.
let scale: CGFloat = 4.4783
let offset: CGFloat = 64.17
func m(_ v: CGFloat) -> CGFloat { v * scale + offset }
func mrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: m(x), y: m(y), width: w * scale, height: h * scale)
}
func mp(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: m(x), y: m(y)) }

func dot(_ ctx: CGContext, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ c: CGColor) {
    ctx.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
    ctx.setFillColor(c); ctx.fillPath()
}

func drawIcon(_ ctx: CGContext, size: CGFloat) {
    let k = size / 1024.0
    ctx.saveGState()
    ctx.translateBy(x: 0, y: size)   // flip to a top-left origin (SVG-like)
    ctx.scaleBy(x: k, y: -k)

    // Background squircle + gradient + top gloss
    let sq = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.saveGState()
    ctx.addPath(rr(sq, 185)); ctx.clip()
    ctx.drawLinearGradient(CGGradient(colorsSpace: sp,
        colors: [color("#2a3040"), color("#141824")] as CFArray, locations: [0, 1])!,
        start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    ctx.drawLinearGradient(CGGradient(colorsSpace: sp,
        colors: [color("#ffffff", 0.16), color("#ffffff", 0)] as CFArray, locations: [0, 1])!,
        start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 512), options: [])
    ctx.restoreGState()

    let stroke = 3 * scale
    let winRadius = 16 * scale

    // Single terminal window
    let win = mrect(42, 56, 116, 92)
    ctx.addPath(rr(win, winRadius)); ctx.setFillColor(color("#1c2130")); ctx.fillPath()
    ctx.addPath(rr(win, winRadius)); ctx.setStrokeColor(color("#39415a")); ctx.setLineWidth(stroke); ctx.strokePath()

    // Prompt chevron (light) + cursor
    ctx.setStrokeColor(color("#eef2f7")); ctx.setLineWidth(9 * scale)
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.move(to: mp(62, 90)); ctx.addLine(to: mp(80, 104)); ctx.addLine(to: mp(62, 118)); ctx.strokePath()
    ctx.addPath(rr(mrect(90, 112, 40, 8), 4 * scale)); ctx.setFillColor(color("#5b667e")); ctx.fillPath()

    // Coral spark badge (top-right)
    let s = CGMutablePath()
    s.move(to: mp(150, 44))
    s.addCurve(to: mp(173, 67), control1: mp(153, 60), control2: mp(157, 64))
    s.addCurve(to: mp(150, 90), control1: mp(157, 70), control2: mp(153, 74))
    s.addCurve(to: mp(127, 67), control1: mp(147, 74), control2: mp(143, 70))
    s.addCurve(to: mp(150, 44), control1: mp(143, 64), control2: mp(147, 60))
    s.closeSubpath()
    ctx.addPath(s); ctx.setFillColor(color("#e8875f")); ctx.fillPath()

    ctx.restoreGState()
}

func renderPNG(size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: sp,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    drawIcon(ctx, size: CGFloat(size))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let specs: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in specs {
    try! renderPNG(size: px).write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    print("wrote \(name).png (\(px)px)")
}
