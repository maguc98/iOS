import AppKit
import Foundation

let output = CommandLine.arguments[1]
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
NSColor.white.setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
let blue = NSColor(calibratedRed: 0.42, green: 0.66, blue: 1.0, alpha: 1.0)
blue.setStroke()
blue.setFill()

let body = NSBezierPath(roundedRect: NSRect(x: 175, y: 235, width: 675, height: 440), xRadius: 105, yRadius: 105)
body.lineWidth = 34
body.stroke()
let top = NSBezierPath(roundedRect: NSRect(x: 390, y: 645, width: 245, height: 95), xRadius: 48, yRadius: 48)
top.lineWidth = 30
top.stroke()
let lens = NSBezierPath(ovalIn: NSRect(x: 365, y: 280, width: 295, height: 295))
lens.lineWidth = 34
lens.stroke()
NSBezierPath(ovalIn: NSRect(x: 710, y: 544, width: 60, height: 60)).fill()

func sparkle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: x, y: y-r))
    p.curve(to: NSPoint(x: x+r, y: y), controlPoint1: NSPoint(x: x+10, y: y-10), controlPoint2: NSPoint(x: x+r-10, y: y-10))
    p.curve(to: NSPoint(x: x, y: y+r), controlPoint1: NSPoint(x: x+r-10, y: y+10), controlPoint2: NSPoint(x: x+10, y: y+10))
    p.curve(to: NSPoint(x: x-r, y: y), controlPoint1: NSPoint(x: x-10, y: y+10), controlPoint2: NSPoint(x: x-r+10, y: y+10))
    p.curve(to: NSPoint(x: x, y: y-r), controlPoint1: NSPoint(x: x-r+10, y: y-10), controlPoint2: NSPoint(x: x-10, y: y-10))
    p.close()
    p.fill()
}
sparkle(285, 770, 52)
sparkle(190, 680, 28)
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Unable to render AppIcon.png")
}
try png.write(to: URL(fileURLWithPath: output))
