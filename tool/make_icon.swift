// Renders the Winter app icon (1024×1024 PNG). Usage: swift tool/make_icon.swift out.png
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Rounded square with a night-sky gradient (macOS icon grid: 824pt body).
let inset: CGFloat = 100
let body = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
ctx.saveGState()
shape.addClip()
NSGradient(colors: [NSColor(red: 0.04, green: 0.07, blue: 0.20, alpha: 1),
                    NSColor(red: 0.10, green: 0.22, blue: 0.48, alpha: 1)])!
  .draw(in: body, angle: 90)
// Moon glow.
NSGradient(colors: [NSColor(white: 1, alpha: 0.35), NSColor(white: 1, alpha: 0)])!
  .draw(fromCenter: NSPoint(x: 700, y: 720), radius: 0, toCenter: NSPoint(x: 700, y: 720), radius: 260, options: [])
NSColor(red: 1, green: 0.98, blue: 0.9, alpha: 1).setFill()
NSBezierPath(ovalIn: CGRect(x: 650, y: 670, width: 100, height: 100)).fill()
// Snow drift.
let drift = NSBezierPath()
drift.move(to: NSPoint(x: inset, y: inset))
drift.line(to: NSPoint(x: inset, y: 300))
drift.curve(to: NSPoint(x: 560, y: 270), controlPoint1: NSPoint(x: 260, y: 360), controlPoint2: NSPoint(x: 420, y: 330))
drift.curve(to: NSPoint(x: size - inset, y: 330), controlPoint1: NSPoint(x: 700, y: 210), controlPoint2: NSPoint(x: 820, y: 360))
drift.line(to: NSPoint(x: size - inset, y: inset))
drift.close()
NSGradient(colors: [NSColor(red: 0.80, green: 0.87, blue: 0.96, alpha: 1), NSColor.white])!.draw(in: drift, angle: 90)
// Icicles along the top edge.
NSColor(red: 0.85, green: 0.94, blue: 1, alpha: 0.9).setFill()
var x: CGFloat = inset + 40
let lengths: [CGFloat] = [70, 120, 50, 160, 80, 110, 60, 140, 90]
for len in lengths {
  let p = NSBezierPath()
  p.move(to: NSPoint(x: x - 16, y: size - inset))
  p.line(to: NSPoint(x: x, y: size - inset - len))
  p.line(to: NSPoint(x: x + 16, y: size - inset))
  p.close()
  p.fill()
  x += 88
}
ctx.restoreGState()

// Snowflake.
let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
if let flake = NSImage(systemSymbolName: "snowflake", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
  let tinted = NSImage(size: flake.size)
  tinted.lockFocus()
  flake.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
  NSColor.white.set()
  NSRect(origin: .zero, size: flake.size).fill(using: .sourceAtop)
  tinted.unlockFocus()
  let r = CGRect(x: (size - flake.size.width) / 2, y: (size - flake.size.height) / 2 - 10,
                 width: flake.size.width, height: flake.size.height)
  let shadow = NSShadow()
  shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
  shadow.shadowBlurRadius = 24
  shadow.shadowOffset = NSSize(width: 0, height: -8)
  shadow.set()
  tinted.draw(in: r)
}
image.unlockFocus()

let rep = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
