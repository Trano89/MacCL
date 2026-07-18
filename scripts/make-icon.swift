// Generates AppIcon.png (1024×1024) — MacCL's app icon.
//
// Concept: a prompt chevron (coding) wrapped in a looping arrow (the agent
// iterating on its own). Original geometry, app accent color — deliberately
// nothing resembling anyone else's branding.
//
// Usage: swift scripts/make-icon.swift <output.png>

import AppKit
import CoreGraphics

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let S: CGFloat = 1024

let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgba(_ hex: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// ---- macOS icon plate: centered rounded rect with the standard margins ------
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()
// Deep charcoal, slightly warm, vertical gradient — matches the app's dark UI.
let bg = CGGradient(colorsSpace: nil,
                    colors: [rgba(0x2B2B31), rgba(0x141417)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: S/2, y: plate.maxY),
                       end: CGPoint(x: S/2, y: plate.minY), options: [])

// Faint grid of dots — a nod to a code editor's gutter, barely visible.
ctx.setFillColor(rgba(0xFFFFFF, 0.035))
for gx in stride(from: 180, through: 844, by: 83) {
    for gy in stride(from: 180, through: 844, by: 83) {
        ctx.fillEllipse(in: CGRect(x: CGFloat(gx) - 4, y: CGFloat(gy) - 4, width: 8, height: 8))
    }
}
ctx.restoreGState()

// Subtle top edge highlight on the plate.
ctx.addPath(CGPath(roundedRect: plate.insetBy(dx: 3, dy: 3),
                   cornerWidth: 183, cornerHeight: 183, transform: nil))
ctx.setStrokeColor(rgba(0xFFFFFF, 0.06))
ctx.setLineWidth(6)
ctx.strokePath()

let coral = 0xE37654
let coralLight = 0xF29C7C

// ---- The agent loop: an open circular arrow around the glyph ---------------
// Open circle (gap at the lower right) with an arrowhead — iteration, running
// on its own until done.
let center = CGPoint(x: 512, y: 512)
let radius: CGFloat = 300
let startAngle: CGFloat = 3.55    // lower-left…
let endAngle: CGFloat = -0.75    // …over the top, ending lower-right
ctx.setStrokeColor(rgba(0x9A9AA2, 0.88))
ctx.setLineWidth(38)
ctx.setLineCap(.round)
ctx.addArc(center: center, radius: radius, startAngle: startAngle,
           endAngle: endAngle, clockwise: true)
ctx.strokePath()

// Arrowhead at the arc's end, pointing along the (clockwise) tangent.
let tip = CGPoint(x: center.x + radius * cos(endAngle), y: center.y + radius * sin(endAngle))
let tangent = endAngle - .pi / 2
func pt(_ base: CGPoint, _ angle: CGFloat, _ dist: CGFloat) -> CGPoint {
    CGPoint(x: base.x + dist * cos(angle), y: base.y + dist * sin(angle))
}
ctx.setFillColor(rgba(0x9A9AA2, 0.88))
ctx.move(to: pt(tip, tangent, 96))
ctx.addLine(to: pt(tip, tangent + 2.35, 66))
ctx.addLine(to: pt(tip, tangent - 2.35, 66))
ctx.closePath()
ctx.fillPath()

// ---- The prompt: chevron + cursor, front and center ------------------------
// Chevron ">" in the accent color, with a soft glow so it reads at 16 px.
ctx.setShadow(offset: .zero, blur: 60, color: rgba(coral, 0.55))
let chevron = CGMutablePath()
chevron.move(to: CGPoint(x: 356, y: 668))
chevron.addLine(to: CGPoint(x: 520, y: 512))
chevron.addLine(to: CGPoint(x: 356, y: 356))
ctx.addPath(chevron)
let coralStroke = CGGradient(colorsSpace: nil,
                             colors: [rgba(coralLight), rgba(coral)] as CFArray,
                             locations: [0, 1])!
ctx.setLineWidth(92)
ctx.setLineJoin(.round)
ctx.setLineCap(.round)
ctx.replacePathWithStrokedPath()
ctx.clip()
ctx.drawLinearGradient(coralStroke, start: CGPoint(x: 356, y: 668),
                       end: CGPoint(x: 356, y: 356),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.resetClip()

// Blinking-cursor block, off-white, to the right of the chevron.
ctx.setShadow(offset: .zero, blur: 30, color: rgba(0xFFFFFF, 0.25))
let cursor = CGPath(roundedRect: CGRect(x: 584, y: 468, width: 152, height: 88),
                    cornerWidth: 18, cornerHeight: 18, transform: nil)
ctx.addPath(cursor)
ctx.setFillColor(rgba(0xECECF0))
ctx.fillPath()

// ---- Write PNG --------------------------------------------------------------
let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL,
                                           "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out)")
