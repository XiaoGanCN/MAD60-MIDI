// makeicon.swift — renders the MagMIDI app icon into an .appiconset.
// Usage: makeicon <output-directory>

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func makeIcon(_ size: Int) -> CGImage? {
    let s = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setAllowsAntialiasing(true)

    // Squircle background with a deep indigo -> violet gradient.
    let inset = s * 0.055
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squircle = CGPath(roundedRect: body, cornerWidth: s * 0.225, cornerHeight: s * 0.225, transform: nil)
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    if let gradient = CGGradient(colorsSpace: space,
                                 colors: [CGColor(red: 0.11, green: 0.09, blue: 0.28, alpha: 1),
                                          CGColor(red: 0.36, green: 0.19, blue: 0.70, alpha: 1),
                                          CGColor(red: 0.55, green: 0.27, blue: 0.85, alpha: 1)] as CFArray,
                                 locations: [0, 0.55, 1]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    }
    ctx.restoreGState()

    // Travel waveform across the upper half.
    let wave = CGMutablePath()
    wave.move(to: CGPoint(x: s * 0.14, y: s * 0.66))
    let steps = 60
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps)
        let x = s * 0.14 + t * s * 0.72
        let envelope = sin(t * .pi)
        let y = s * 0.66 + sin(t * .pi * 3.0) * s * 0.085 * envelope
        wave.addLine(to: CGPoint(x: x, y: y))
    }
    ctx.saveGState()
    ctx.addPath(wave)
    ctx.setStrokeColor(CGColor(red: 0.80, green: 0.90, blue: 1.0, alpha: 0.95))
    ctx.setLineWidth(max(1, s * 0.045))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()

    // Piano keys along the bottom.
    let keyTop = s * 0.44
    let keyBottom = s * 0.20
    let whiteCount = 6
    let gap = s * 0.018
    let totalWidth = s * 0.72
    let left = s * 0.14
    let keyWidth = (totalWidth - gap * CGFloat(whiteCount - 1)) / CGFloat(whiteCount)
    for index in 0..<whiteCount {
        // Travel height varies a little so the keys look played.
        let height = (keyBottom - keyTop) * CGFloat(0.78 + 0.22 * Double((index * 7) % 5) / 4.0)
        let rect = CGRect(x: left + CGFloat(index) * (keyWidth + gap), y: keyBottom,
                          width: keyWidth, height: height)
        let path = CGPath(roundedRect: rect, cornerWidth: keyWidth * 0.22, cornerHeight: keyWidth * 0.22, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 1.0, alpha: 0.96))
        ctx.fillPath()
    }
    // A couple of black keys for the piano read.
    let blackIndices = [0, 1, 3, 4]
    for index in blackIndices where index < whiteCount - 1 {
        let x = left + CGFloat(index + 1) * (keyWidth + gap) - gap * 0.5 - keyWidth * 0.28
        let rect = CGRect(x: x, y: keyBottom + (keyBottom - keyTop) * 0.42,
                          width: keyWidth * 0.56, height: (keyBottom - keyTop) * 0.52)
        let path = CGPath(roundedRect: rect, cornerWidth: keyWidth * 0.14, cornerHeight: keyWidth * 0.14, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 0.10, green: 0.08, blue: 0.22, alpha: 0.92))
        ctx.fillPath()
    }

    return ctx.makeImage()
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

struct Entry { let size: Int; let scale: Int; let name: String }
let entries = [
    Entry(size: 16, scale: 1, name: "icon_16x16.png"),
    Entry(size: 16, scale: 2, name: "icon_16x16@2x.png"),
    Entry(size: 32, scale: 1, name: "icon_32x32.png"),
    Entry(size: 32, scale: 2, name: "icon_32x32@2x.png"),
    Entry(size: 128, scale: 1, name: "icon_128x128.png"),
    Entry(size: 128, scale: 2, name: "icon_128x128@2x.png"),
    Entry(size: 256, scale: 1, name: "icon_256x256.png"),
    Entry(size: 256, scale: 2, name: "icon_256x256@2x.png"),
    Entry(size: 512, scale: 1, name: "icon_512x512.png"),
    Entry(size: 512, scale: 2, name: "icon_512x512@2x.png"),
]

for entry in entries {
    let pixels = entry.size * entry.scale
    guard let image = makeIcon(pixels) else { print("render failed for \(pixels)"); continue }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(entry.name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(entry.name) (\(pixels)px)")
}

// Contents.json for the appiconset
var images: [String] = []
for entry in entries {
    images.append("""
        {
          "filename" : "\(entry.name)",
          "idiom" : "mac",
          "scale" : "\(entry.scale)x",
          "size" : "\(entry.size)x\(entry.size)"
        }
    """)
}
let contents = """
{
  "images" : [
\(images.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
try? contents.write(toFile: (outDir as NSString).appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote Contents.json")
