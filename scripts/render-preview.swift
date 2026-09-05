// Renders docs/preview.png without a screen capture: draws the exact layout
// MeterColumnView draws — a direct port of Stats' own "Mini" widget, both
// lines left-aligned (not centered) — as three separate boxes on a
// menu-bar-shaped strip, at 2x for Retina.
//   swift scripts/render-preview.swift

import AppKit

let severityColor: (Double) -> NSColor = { pct in
    if pct >= 90 { return NSColor(srgbRed: 0.878, green: 0.322, blue: 0.290, alpha: 1) }
    if pct >= 70 { return NSColor(srgbRed: 0.878, green: 0.639, blue: 0.149, alpha: 1) }
    return NSColor(srgbRed: 0.298, green: 0.686, blue: 0.490, alpha: 1)
}

// Demo readings: one of each severity so the preview shows the palette.
// Display order: ZAI, Weekly, Claude.
let readings: [(label: String, pct: Int)] = [
    ("ZAI", 46),
    ("Weekly", 12),
    ("Claude", 78),
]

let labelFont = NSFont.systemFont(ofSize: 7, weight: .light)
let valueFont = NSFont.systemFont(ofSize: 12, weight: .regular)
let white = NSColor.white
let leftStyle: NSParagraphStyle = {
    let style = NSMutableParagraphStyle()
    style.alignment = .left
    return style
}()

func labelString(_ label: String) -> NSAttributedString {
    NSAttributedString(string: label, attributes: [.font: labelFont, .foregroundColor: white, .paragraphStyle: leftStyle])
}
func valueString(_ pct: Int) -> NSAttributedString {
    NSAttributedString(string: "\(pct)%", attributes: [
        .font: valueFont, .foregroundColor: severityColor(Double(pct)), .paragraphStyle: leftStyle,
    ])
}

let boxHeight: CGFloat = 22
let gap: CGFloat = 12 // menu bar spacing between separate NSStatusItems

let boxWidths = readings.map { r in
    max(labelString(r.label).size().width, valueString(r.pct).size().width).rounded(.up) + 4
}
let totalWidth = boxWidths.reduce(0, +) + gap * CGFloat(readings.count - 1) + 40

let image = NSImage(size: NSSize(width: totalWidth, height: 30))
image.lockFocus()
NSColor(calibratedWhite: 0.08, alpha: 0.92).setFill()
NSRect(x: 0, y: 0, width: totalWidth, height: 30).fill()
NSColor.white.withAlphaComponent(0.12).setFill()
NSRect(x: 0, y: 0, width: totalWidth, height: 0.5).fill()

var x: CGFloat = 20
let barTop: CGFloat = 30
let barBottom: CGFloat = 30 - boxHeight // boxes sit flush with the bottom of the strip, like real menu-bar items
for (i, r) in readings.enumerated() {
    let width = boxWidths[i]
    let labelRect = NSRect(x: x, y: barBottom + boxHeight - 10, width: width, height: 7)
    let valueRect = NSRect(x: x, y: barBottom + 1, width: width, height: 13)
    labelString(r.label).draw(with: labelRect)
    valueString(r.pct).draw(with: valueRect)
    x += width + gap
}
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
