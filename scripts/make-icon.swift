// Gera Resources/AppIcon.icns: uma fatia de toranja.
// Uso: swift scripts/make-icon.swift <pasta-de-saída>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
let px = 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let rect = NSRect(x: 0, y: 0, width: px, height: px)
let c = NSPoint(x: rect.midX, y: rect.midY)
func circle(_ r: CGFloat) -> NSBezierPath { NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)) }

// Fundo arredondado no formato padrão de ícone do macOS.
let bg = NSBezierPath(roundedRect: rect.insetBy(dx: 100, dy: 100), xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(srgbRed: 1.0, green: 0.97, blue: 0.93, alpha: 1),
           ending: NSColor(srgbRed: 1.0, green: 0.89, blue: 0.83, alpha: 1))!.draw(in: bg, angle: -90)

NSColor(srgbRed: 0.97, green: 0.56, blue: 0.27, alpha: 1).setFill()   // casca
circle(320).fill()
NSColor(srgbRed: 1.0, green: 0.94, blue: 0.86, alpha: 1).setFill()    // parte branca
circle(290).fill()

NSColor(srgbRed: 0.95, green: 0.36, blue: 0.38, alpha: 1).setFill()   // gomos
let segments = 10
for i in 0..<segments {
    let mid = CGFloat(i) * 360 / CGFloat(segments) + 90
    let half = 360 / CGFloat(segments) / 2 - 3.2
    let wedge = NSBezierPath()
    wedge.appendArc(withCenter: c, radius: 268, startAngle: mid - half, endAngle: mid + half)
    wedge.appendArc(withCenter: c, radius: 34, startAngle: mid + half + 8, endAngle: mid - half - 8, clockwise: true)
    wedge.close()
    wedge.fill()
}
NSGraphicsContext.restoreGraphicsState()

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = iconset.appendingPathComponent("icon_512x512@2x.png")
try! rep.representation(using: .png, properties: [:])!.write(to: master)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] where !(size == 512 && scale == 2) {
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        p.arguments = ["-z", "\(size * scale)", "\(size * scale)", master.path, "--out", iconset.appendingPathComponent(name).path]
        p.standardOutput = FileHandle.nullDevice
        try! p.run()
        p.waitUntilExit()
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
print("Ícone gerado em \(outDir.path)/AppIcon.icns")
