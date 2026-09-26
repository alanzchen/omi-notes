// Renders the 1024×1024 app icon (opaque PNG, as App Store Connect requires).
// Usage: swift ios/Tools/make_app_icon.swift ios/OmiNotes/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
// Drawn from primitives on purpose: SF Symbols may not be used in app icons.
import AppKit

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

// Opaque bitmap (no alpha channel): NSGraphicsContext can't draw into an alpha-less
// NSBitmapImageRep, so draw through a CoreGraphics context that skips alpha.
guard let cg = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { fatalError("bitmap") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
let rect = NSRect(x: 0, y: 0, width: size, height: size)

// Background: deep indigo → teal diagonal gradient.
NSGradient(colors: [
    NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.28, alpha: 1),
    NSColor(calibratedRed: 0.05, green: 0.42, blue: 0.55, alpha: 1),
])!.draw(in: rect, angle: 60)

// A waveform of rounded bars (the pendant listening) resting on a page-like baseline (the notes).
let heights: [CGFloat] = [0.16, 0.30, 0.52, 0.72, 0.46, 0.84, 0.60, 0.36, 0.22]
let barWidth: CGFloat = 58
let gap: CGFloat = 30
let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = (CGFloat(size) - total) / 2
let centerY = CGFloat(size) * 0.54
NSColor.white.setFill()
for h in heights {
    let barHeight = h * 560
    let bar = NSRect(x: x, y: centerY - barHeight / 2, width: barWidth, height: barHeight)
    NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    x += barWidth + gap
}

// Three "note lines" under the waveform.
NSColor(calibratedWhite: 1, alpha: 0.55).setFill()
for (i, width) in [520.0, 420.0, 300.0].enumerated() {
    let y = CGFloat(size) * 0.22 - CGFloat(i) * 52
    let line = NSRect(x: (CGFloat(size) - width) / 2, y: y, width: width, height: 22)
    NSBezierPath(roundedRect: line, xRadius: 11, yRadius: 11).fill()
}

NSGraphicsContext.restoreGraphicsState()
guard let image = cg.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
else { fatalError("png") }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
