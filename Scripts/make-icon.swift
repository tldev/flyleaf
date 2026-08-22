// Renders the Flyleaf app icon (warm paper, serif F, orange accent) to a
// 1024x1024 PNG. Scripts/build-app.sh turns it into AppIcon.icns.
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// Rounded-rect plate with a little padding, warm paper gradient.
let inset = 84.0
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius = 200.0
let plate = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
plate.addClip()
let gradient = NSGradient(colors: [color(0xF6F3EC), color(0xE9E3D4)])!
gradient.draw(in: rect, angle: -90)

// Soft top highlight.
color(0xFFFFFF).withAlphaComponent(0.35).setFill()
NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), xRadius: radius, yRadius: radius).fill()
gradient.draw(in: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.62), angle: -90)

// Serif F.
let f = "F" as NSString
let font = NSFont(name: "Georgia-Bold", size: 620) ?? NSFont.systemFont(ofSize: 620, weight: .bold)
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(0x201C15)]
let textSize = f.size(withAttributes: attrs)
f.draw(at: NSPoint(x: (size - textSize.width) / 2 - 6, y: (size - textSize.height) / 2 + 8), withAttributes: attrs)

// Orange accent bar (a bookmark tick) bottom-left of the F.
color(0xB45309).setFill()
NSBezierPath(roundedRect: NSRect(x: 372, y: 300, width: 190, height: 30), xRadius: 15, yRadius: 15).fill()

// Thin inner keyline.
color(0x000000).withAlphaComponent(0.06).setStroke()
let key = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
key.lineWidth = 2
key.stroke()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("icon render failed\n".data(using: .utf8)!)
    exit(1)
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-master.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
