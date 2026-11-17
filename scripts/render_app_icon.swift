// Original geometric artwork for 言出文随. No external art, fonts or model assets.
// Reproduce on macOS: swift scripts/render_app_icon.swift
import AppKit
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("VoicePolishApp/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func render(_ size: Int, _ name: String) throws {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    ctx.scaleBy(x: CGFloat(size)/1024, y: CGFloat(size)/1024)
    // Full bleed: iOS applies its own corner mask, never bake one into the art.
    let gradient = NSGradient(starting: NSColor(srgbRed: 0.035, green: 0.16, blue: 0.24, alpha: 1),
                              ending: NSColor(srgbRed: 0.03, green: 0.58, blue: 0.57, alpha: 1))!
    gradient.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024), angle: 55)
    // A warm-white speech card, with a single rounded tail.
    NSColor(srgbRed: 0.97, green: 0.99, blue: 0.96, alpha: 1).setFill()
    let card = NSBezierPath(roundedRect: NSRect(x: 160, y: 280, width: 704, height: 484), xRadius: 116, yRadius: 116)
    card.fill()
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: 300, y: 325)); tail.line(to: NSPoint(x: 300, y: 210))
    tail.curve(to: NSPoint(x: 324, y: 198), controlPoint1: NSPoint(x: 300, y: 197), controlPoint2: NSPoint(x: 313, y: 190))
    tail.line(to: NSPoint(x: 450, y: 295)); tail.close(); tail.fill()
    func capsule(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: NSColor) {
        color.setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: min(w,h)/2, yRadius: min(w,h)/2).fill()
    }
    let ink = NSColor(srgbRed: 0.04, green: 0.30, blue: 0.36, alpha: 1)
    let mint = NSColor(srgbRed: 0.02, green: 0.61, blue: 0.55, alpha: 1)
    // Sound on the left resolves into readable lines on the right.
    capsule(240, 465, 40, 110, mint)
    capsule(306, 409, 40, 222, mint)
    capsule(372, 370, 40, 300, ink)
    capsule(438, 429, 40, 182, ink)
    capsule(530, 604, 240, 42, ink)
    capsule(530, 500, 195, 42, ink)
    capsule(530, 396, 146, 42, mint)
    NSGraphicsContext.restoreGraphicsState()
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}
try render(1024, "AppIcon.png")
let manifest = """
{"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
"""
try manifest.write(to: output.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
try "{\"info\":{\"author\":\"xcode\",\"version\":1}}\n".write(to: output.deletingLastPathComponent().appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
