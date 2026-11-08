import AppKit
let out = CommandLine.arguments[1]
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let rect = NSRect(x: 56, y: 56, width: 912, height: 912)
let background = NSBezierPath(roundedRect: rect, xRadius: 205, yRadius: 205)
NSColor(calibratedRed: 0.06, green: 0.23, blue: 0.26, alpha: 1).setFill()
background.fill()
let inner = NSBezierPath(roundedRect: NSRect(x: 215, y: 290, width: 550, height: 440), xRadius: 65, yRadius: 65)
NSColor(calibratedRed: 0.33, green: 0.89, blue: 0.76, alpha: 1).setStroke()
inner.lineWidth = 30; inner.stroke()
NSColor(calibratedRed: 0.33, green: 0.89, blue: 0.76, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 780, y: 435, width: 40, height: 150), xRadius: 14, yRadius: 14).fill()
for x in [280, 415, 550] {
    NSBezierPath(roundedRect: NSRect(x: x, y: 355, width: 95, height: 310), xRadius: 18, yRadius: 18).fill()
}
image.unlockFocus()
guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Icon render failed") }
try png.write(to: URL(fileURLWithPath: out))
