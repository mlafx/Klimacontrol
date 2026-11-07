// Zeichnet das App-Symbol (Verlauf blau → orange mit Klimaanlagen-Symbol) als AppIcon.iconset.
// Abhängigkeit: macOS mit Xcode-Kommandozeilenwerkzeugen (AppKit). Danach: iconutil -c icns tools/AppIcon.iconset
// Aufruf:  swift tools/make_icon.swift tools   (build_app.sh kopiert tools/AppIcon.icns in die App)
import AppKit
let out = CommandLine.arguments[1]
let set = out + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for (size, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let px = size * scale
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    let r = NSRect(x: 0, y: 0, width: px, height: px).insetBy(dx: CGFloat(px) * 0.08, dy: CGFloat(px) * 0.08)
    let path = NSBezierPath(roundedRect: r, xRadius: CGFloat(px) * 0.2, yRadius: CGFloat(px) * 0.2)
    NSGradient(colors: [NSColor(red: 0.20, green: 0.55, blue: 0.95, alpha: 1), NSColor(red: 0.96, green: 0.45, blue: 0.18, alpha: 1)])!.draw(in: path, angle: -60)
    let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.45, weight: .medium).applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "air.conditioner.horizontal", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let s = sym.size
        sym.draw(in: NSRect(x: (CGFloat(px) - s.width) / 2, y: (CGFloat(px) - s.height) / 2, width: s.width, height: s.height))
    }
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: set + "/" + name))
}
