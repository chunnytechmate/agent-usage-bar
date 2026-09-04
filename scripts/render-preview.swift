// Renders docs/preview.png without a screen capture: draws the exact attributed
// string the status item shows onto a menu-bar-shaped strip, at 2x for Retina.
//   swift scripts/render-preview.swift

import AppKit

let severityColors: (Double) -> NSColor = { pct in
    if pct >= 90 { return NSColor(srgbRed: 0.878, green: 0.322, blue: 0.290, alpha: 1) }
    if pct >= 70 { return NSColor(srgbRed: 0.878, green: 0.639, blue: 0.149, alpha: 1) }
    return NSColor(srgbRed: 0.298, green: 0.686, blue: 0.490, alpha: 1)
}

// Demo readings: one of each severity so the preview shows the palette.
let readings: [(label: String, pct: Int, reset: String)] = [
    ("C", 78, "resets 04:52 (3h 07m)"),
    ("W", 12, "resets Mon 08:59 (2d 19h)"),
    ("Z", 46, "resets 13:14 (6h 12m)"),
]

func barTitle() -> NSAttributedString {
    let out = NSMutableAttributedString()
    let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    let dim = NSColor.white.withAlphaComponent(0.55)
    for (i, r) in readings.enumerated() {
        if i > 0 { out.append(NSAttributedString(string: "  ·  ", attributes: [.font: labelFont, .foregroundColor: dim])) }
        out.append(NSAttributedString(string: " \(r.label) ", attributes: [.font: labelFont, .foregroundColor: dim]))
        out.append(NSAttributedString(string: "\(r.pct)%", attributes: [.font: valueFont, .foregroundColor: severityColors(Double(r.pct))]))
    }
    return out
}

// A menu-bar-like backdrop: translucent dark strip with a hairline bottom edge.
let scale: CGFloat = 2
let width: CGFloat = 430
let height: CGFloat = 30
let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()
NSColor(calibratedWhite: 0.08, alpha: 0.92).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
NSColor.white.withAlphaComponent(0.12).setFill()
NSRect(x: 0, y: 0, width: width, height: 0.5).fill()

let title = barTitle()
let size = title.size()
title.draw(at: NSPoint(x: (width - size.width) / 2, y: (height - size.height) / 2))
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("preview render failed\n".utf8))
    exit(1)
}
let outPath = URL(fileURLWithPath: "docs/preview.png")
try! png.write(to: outPath)
print("wrote \(outPath.path)")
