// Renders the KiFinder app-icon master (1024×1024 PNG). Pure CoreGraphics
// (no AppKit/fonts) so it runs headlessly via `swift`. Drive it through
// `Scripts/generate_app_icon.sh`, which produces the downscaled sizes.
//
//   swift Scripts/generate_app_icon.swift <outPath.png>
//
// Mark: a calm head-and-shoulders bust framed by the app's signature amber
// face-detection brackets, with a green "keep" check — privacy-first face triage.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outPath = CommandLine.arguments[1]

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: cs,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255,
            a,
        ]
    )!
}

// Palette from DESIGN.md.
let canvasTop = color(0xFBFBF9)
let canvasBottom = color(0xE8E9E4)
let ink = color(0x26272A)
let amber = color(0xC9842C)
let keep = color(0x3B8F61)
let white = color(0xFFFFFF)

let S: CGFloat = 1024
// App icons are flat, opaque, full-bleed RGB; the OS adds the rounded mask +
// shadow, so don't bake in corners, padding, or a drop shadow here.
let ctx = CGContext(
    data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
    space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!
let tile = CGRect(x: 0, y: 0, width: S, height: S)

// Warm-neutral canvas with a subtle top-to-bottom gradient.
ctx.setFillColor(canvasTop)
ctx.fill(tile)
ctx.drawLinearGradient(
    CGGradient(colorsSpace: cs, colors: [canvasTop, canvasBottom] as CFArray, locations: [0, 1])!,
    start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
)

// Detection box the brackets mark (centered square).
let inset: CGFloat = 236
let box = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)

// Head-and-shoulders bust, clipped to the box so the shoulders read as "framed".
ctx.saveGState()
ctx.clip(to: box)
ctx.setFillColor(ink)
// Shoulders: a wide ellipse whose bottom runs past the box (cut flat by the clip).
ctx.fillEllipse(in: CGRect(x: 512 - 232, y: inset - 96, width: 464, height: 430))
// Head.
let headR: CGFloat = 158
ctx.fillEllipse(in: CGRect(x: 512 - headR, y: 640 - headR, width: headR * 2, height: headR * 2))
ctx.restoreGState()

// Amber detection brackets at the four corners of the box.
let arm: CGFloat = 150
let lw: CGFloat = 46
ctx.setStrokeColor(amber)
ctx.setLineWidth(lw)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
func bracket(_ corner: CGPoint, dx: CGFloat, dy: CGFloat) {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
    path.addLine(to: corner)
    path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
    ctx.addPath(path)
    ctx.strokePath()
}
bracket(CGPoint(x: box.minX, y: box.minY), dx: 1, dy: 1) // bottom-left
bracket(CGPoint(x: box.maxX, y: box.minY), dx: -1, dy: 1) // bottom-right
bracket(CGPoint(x: box.minX, y: box.maxY), dx: 1, dy: -1) // top-left
bracket(CGPoint(x: box.maxX, y: box.maxY), dx: -1, dy: -1) // top-right

// Green "keep" check badge on the bottom-right corner.
let badgeC = CGPoint(x: box.maxX, y: box.minY)
let badgeR: CGFloat = 112
ctx.setFillColor(white)
ctx.fillEllipse(in: CGRect(x: badgeC.x - badgeR - 12, y: badgeC.y - badgeR - 12, width: (badgeR + 12) * 2, height: (badgeR + 12) * 2))
ctx.setFillColor(keep)
ctx.fillEllipse(in: CGRect(x: badgeC.x - badgeR, y: badgeC.y - badgeR, width: badgeR * 2, height: badgeR * 2))
// Checkmark.
let check = CGMutablePath()
check.move(to: CGPoint(x: badgeC.x - 52, y: badgeC.y + 2))
check.addLine(to: CGPoint(x: badgeC.x - 14, y: badgeC.y - 38))
check.addLine(to: CGPoint(x: badgeC.x + 58, y: badgeC.y + 46))
ctx.setStrokeColor(white)
ctx.setLineWidth(30)
ctx.addPath(check)
ctx.strokePath()

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(
          URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil
      )
else {
    fputs("failed to render icon\n", stderr)
    exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("Wrote \(outPath)")
