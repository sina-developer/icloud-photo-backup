// Renders the app icon (1024x1024 PNG) to the path given as the first argument.
import AppKit

let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 80, y: 80, width: size - 160, height: size - 160)
let bg = NSBezierPath(roundedRect: rect, xRadius: 190, yRadius: 190)
NSGradient(starting: NSColor(calibratedRed: 0.25, green: 0.62, blue: 1, alpha: 1),
           ending: NSColor(calibratedRed: 0.02, green: 0.40, blue: 0.93, alpha: 1))!.draw(in: bg, angle: -90)
if let sym = NSImage(systemSymbolName: "icloud.and.arrow.down.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: 470, weight: .semibold)) {
    let tinted = NSImage(size: sym.size, flipped: false) { r in
        sym.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
    }
    let s = tinted.size
    tinted.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
