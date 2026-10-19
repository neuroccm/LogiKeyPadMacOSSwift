#!/usr/bin/env swift
// Renders the LogiKeyPad app icon: blueprint-blue squircle, white 3x3 key grid.
// Output: assets/AppIcon.iconset/*.png + assets/AppIcon.icns (via iconutil).
// Run: swift scripts/make-icon.swift

import Foundation
import AppKit

let canvas = 1024
let bodyInset: CGFloat = 100          // Apple icon grid: 824x824 body
let bodySize = CGFloat(canvas) - bodyInset * 2
let corner: CGFloat = 185             // squircle-ish radius for 824 body

func renderIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let scale = CGFloat(pixels) / CGFloat(canvas)
    ctx.cgContext.scaleBy(x: scale, y: scale)

    // Body: blueprint gradient (#0A3AFF → #031A7A), top-light.
    let body = NSRect(x: bodyInset, y: bodyInset, width: bodySize, height: bodySize)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: corner, yRadius: corner)
    let gradient = NSGradient(colors: [
        NSColor(red: 0.04, green: 0.23, blue: 1.00, alpha: 1),
        NSColor(red: 0.02, green: 0.18, blue: 0.85, alpha: 1),
        NSColor(red: 0.01, green: 0.10, blue: 0.48, alpha: 1),
    ], atLocations: [0, 0.55, 1], colorSpace: .deviceRGB)!
    gradient.draw(in: bodyPath, angle: -90)

    // Subtle top sheen.
    let sheen = NSGradient(colors: [NSColor.white.withAlphaComponent(0.20),
                                    NSColor.white.withAlphaComponent(0.0)])!
    sheen.draw(in: bodyPath, angle: -90)

    // 3x3 key grid centered in body; center key solid white, others frosted.
    let key: CGFloat = 168
    let gap: CGFloat = 34
    let grid = key * 3 + gap * 2
    let gx = (CGFloat(canvas) - grid) / 2
    let gy = (CGFloat(canvas) - grid) / 2
    for row in 0..<3 {
        for col in 0..<3 {
            let rect = NSRect(x: gx + CGFloat(col) * (key + gap),
                              y: gy + CGFloat(row) * (key + gap),
                              width: key, height: key)
            let kp = NSBezierPath(roundedRect: rect, xRadius: 36, yRadius: 36)
            let isCenter = (row == 1 && col == 1)
            if isCenter {
                NSColor.white.setFill()
                kp.fill()
                // Blue command dot in the heart key.
                let dot: CGFloat = 54
                let dotRect = NSRect(x: rect.midX - dot / 2, y: rect.midY - dot / 2, width: dot, height: dot)
                NSColor(red: 0.02, green: 0.18, blue: 0.85, alpha: 1).setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            } else {
                NSColor.white.withAlphaComponent(0.88).setFill()
                kp.fill()
                NSColor.white.withAlphaComponent(0.35).setStroke()
                kp.lineWidth = 3
                kp.stroke()
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = "assets/AppIcon.iconset"
try? fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in sizes {
    let rep = renderIcon(pixels: px)
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png \(name)") }
    try! png.write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
    print("\(name) \(px)px \(png.count)B")
}
// Keep the master for quick viewing.
let master = renderIcon(pixels: 1024)
try! master.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "assets/AppIcon-1024.png"))
print("master written")
