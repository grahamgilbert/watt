#!/usr/bin/env swift
// Generates Watt's app icon set by compositing the SF Symbol
// `bolt.batteryblock.fill` onto a rounded squircle background.
//
// Run via:
//   swift -target arm64-apple-macos26.0 scripts/GenerateIcons.swift
//
// Outputs PNGs into Watt/Assets.xcassets/AppIcon.appiconset/ at every size
// the macOS app-icon contract requires.

import AppKit
import CoreGraphics
import Foundation

struct IconSpec {
    let pixelSize: Int
    let filename: String
}

// macOS app-icon contract — every size with @1x and @2x variants flattened
// into actual pixel sizes. Apple expects 16, 32, 64, 128, 256, 512, 1024.
let specs: [IconSpec] = [
    IconSpec(pixelSize: 16,   filename: "icon_16x16.png"),
    IconSpec(pixelSize: 32,   filename: "icon_16x16@2x.png"),
    IconSpec(pixelSize: 32,   filename: "icon_32x32.png"),
    IconSpec(pixelSize: 64,   filename: "icon_32x32@2x.png"),
    IconSpec(pixelSize: 128,  filename: "icon_128x128.png"),
    IconSpec(pixelSize: 256,  filename: "icon_128x128@2x.png"),
    IconSpec(pixelSize: 256,  filename: "icon_256x256.png"),
    IconSpec(pixelSize: 512,  filename: "icon_256x256@2x.png"),
    IconSpec(pixelSize: 512,  filename: "icon_512x512.png"),
    IconSpec(pixelSize: 1024, filename: "icon_512x512@2x.png")
]

func renderIcon(pixelSize: Int) -> Data? {
    let size = CGFloat(pixelSize)
    let scale: CGFloat = 1
    let canvas = CGSize(width: size, height: size)

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // 1. Background: rounded squircle with a vertical amber gradient.
    //    The 22.4% corner radius matches the macOS Big Sur+ system icon shape.
    let cornerRadius = size * 0.2237
    let rect = NSRect(origin: .zero, size: canvas)
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    path.addClip()

    let topColor = NSColor(srgbRed: 1.00, green: 0.78, blue: 0.20, alpha: 1.0)     // bright amber
    let bottomColor = NSColor(srgbRed: 0.99, green: 0.55, blue: 0.10, alpha: 1.0)  // saturated orange
    if let gradient = NSGradient(starting: topColor, ending: bottomColor) {
        gradient.draw(in: rect, angle: -90)
    }

    // 2. Subtle inner highlight along the top edge for depth.
    let highlight = NSBezierPath(
        roundedRect: NSRect(x: 0, y: size * 0.6, width: size, height: size * 0.4),
        xRadius: cornerRadius,
        yRadius: cornerRadius
    )
    NSColor.white.withAlphaComponent(0.10).setFill()
    highlight.fill()

    // 3. Foreground: the SF Symbol, rendered in deep charcoal so it stays
    //    legible whether the dock is light or dark.
    let symbolName = "bolt.batteryblock.fill"
    let pointSize = size * 0.62
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
    guard let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Watt")?
        .withSymbolConfiguration(config) else {
        return nil
    }

    // Render the symbol into a tinted bitmap so we can stamp it on the canvas.
    let tint = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.16, alpha: 1.0)
    let tintedImage = NSImage(size: baseImage.size, flipped: false) { rect in
        baseImage.draw(in: rect)
        tint.set()
        rect.fill(using: .sourceAtop)
        return true
    }

    let symbolRect = NSRect(
        x: (size - tintedImage.size.width) / 2,
        y: (size - tintedImage.size.height) / 2,
        width: tintedImage.size.width,
        height: tintedImage.size.height
    )

    // Soft shadow underneath the symbol so the bolt has weight.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.shadowBlurRadius = size * 0.025
    shadow.set()
    tintedImage.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1.0)

    _ = scale

    // Export to PNG.
    guard let cgImage = ctx.makeImage() else { return nil }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    bitmap.size = canvas
    return bitmap.representation(using: .png, properties: [:])
}

let outputDir = ProcessInfo.processInfo.environment["WATT_ICON_DIR"]
    ?? "Watt/Assets.xcassets/AppIcon.appiconset"
let fm = FileManager.default
try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

var generated: [String] = []
for spec in specs {
    guard let data = renderIcon(pixelSize: spec.pixelSize) else {
        FileHandle.standardError.write(Data("Failed to render \(spec.filename)\n".utf8))
        exit(1)
    }
    let url = URL(fileURLWithPath: outputDir).appendingPathComponent(spec.filename)
    do {
        try data.write(to: url)
        generated.append(spec.filename)
    } catch {
        FileHandle.standardError.write(Data("Failed to write \(spec.filename): \(error)\n".utf8))
        exit(1)
    }
}

print("Wrote \(generated.count) icons to \(outputDir):")
for name in generated { print("  - \(name)") }
