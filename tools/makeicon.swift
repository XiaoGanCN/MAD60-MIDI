// makeicon.swift — renders the MagMIDI app icon into an .appiconset.
//
// Usage: makeicon <output-directory>
//
// Geometry notes (these are the whole point of this file):
//
//  * macOS 26 scales legacy .icns artwork into its own icon grid, so artwork that
//    already carries a margin ends up double-padded and the icon looks small next
//    to native ones.  The squircle is therefore drawn **full bleed**, corner to
//    corner, and only the *content* is inset.
//  * Everything is clipped to the squircle, so nothing — in particular the piano
//    keys — can spill outside the icon body.

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
    ctx.setShouldAntialias(true)

    // Apple's macOS icon corner ratio: 185.4 / 824 ≈ 0.225.
    let radius = s * 0.225
    let squircle = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                          cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // Background gradient: highlight top-left, depth bottom-right.
    let space = CGColorSpaceCreateDeviceRGB()
    if let gradient = CGGradient(colorsSpace: space,
                                 colors: [CGColor(red: 0.45, green: 0.25, blue: 0.84, alpha: 1),
                                          CGColor(red: 0.30, green: 0.16, blue: 0.62, alpha: 1),
                                          CGColor(red: 0.15, green: 0.10, blue: 0.40, alpha: 1)] as CFArray,
                                 locations: [0, 0.5, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: s * 0.12, y: s),
                               end: CGPoint(x: s * 0.88, y: 0),
                               options: [])
    }

    // Piano keyboard along the bottom.
    // The keyboard is sized to the flat part of the squircle's bottom edge and
    // drawn a little past the canvas, so the clip leaves the keys flush with the
    // bottom of the icon rather than floating above it.
    let whiteCount = 5
    let keyboardLeft = s * 0.075
    let keyboardWidth = s * 0.85
    let gap = s * 0.012
    let keyWidth = (keyboardWidth - gap * CGFloat(whiteCount - 1)) / CGFloat(whiteCount)
    let keyBottom = -s * 0.06
    let whiteTop = s * 0.70
    let whiteHeight = whiteTop - keyBottom

    for index in 0..<whiteCount {
        let rect = CGRect(x: keyboardLeft + CGFloat(index) * (keyWidth + gap),
                          y: keyBottom, width: keyWidth, height: whiteHeight)
        ctx.addPath(CGPath(roundedRect: rect,
                           cornerWidth: keyWidth * 0.07, cornerHeight: keyWidth * 0.07,
                           transform: nil))
        ctx.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 1.0, alpha: 0.97))
        ctx.fillPath()
    }

    // Black keys sit between the white ones, hanging from their top edge.
    let blackHeight = whiteHeight * 0.52
    for index in [0, 1, 3] where index < whiteCount - 1 {
        let centre = keyboardLeft + CGFloat(index + 1) * (keyWidth + gap) - gap * 0.5
        let rect = CGRect(x: centre - keyWidth * 0.32,
                          y: whiteTop - blackHeight,
                          width: keyWidth * 0.64, height: blackHeight)
        ctx.addPath(CGPath(roundedRect: rect,
                           cornerWidth: keyWidth * 0.10, cornerHeight: keyWidth * 0.10,
                           transform: nil))
        ctx.setFillColor(CGColor(red: 0.13, green: 0.10, blue: 0.28, alpha: 0.95))
        ctx.fillPath()
    }

    ctx.restoreGState()
    return ctx.makeImage()
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

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
