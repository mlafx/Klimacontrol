// Hintergrund des Installations-DMG: Titel, eine Zeile Anleitung und ein Pfeil von der App zu „Programme“.
// Aufruf (aus build_app.sh): swift tools/make_dmg_background.swift <Ausgabe.png> <Skalierung 1|2>
// Maße und Symbolpositionen müssen zu build_app.sh passen (Fenster 640 × 380, Symbole bei x 160 und 480, y 210).
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let scale = Double(args[2]), scale >= 1 else {
    FileHandle.standardError.write(Data("Aufruf: make_dmg_background.swift <Ausgabe.png> <1|2>\n".utf8))
    exit(2)
}
let size = CGSize(width: 640, height: 380)
let px = (w: Int(size.width * scale), h: Int(size.height * scale))
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px.w, pixelsHigh: px.h, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Ruhiger, heller Grund mit sanftem Verlauf (Finder zeichnet die Beschriftungen der Symbole dunkel darauf).
let top = NSColor(srgbRed: 0.965, green: 0.957, blue: 0.937, alpha: 1)
let bottom = NSColor(srgbRed: 0.925, green: 0.933, blue: 0.945, alpha: 1)
NSGradient(starting: top, ending: bottom)?.draw(in: CGRect(origin: .zero, size: size), angle: -90)

func draw(_ text: String, font: NSFont, color: NSColor, centerY: CGFloat) {
    let p = NSMutableParagraphStyle()
    p.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: p]
    let h = (text as NSString).size(withAttributes: attrs).height
    // AppKit zählt y von unten; die Angaben hier gelten von oben wie im Finder.
    (text as NSString).draw(in: CGRect(x: 0, y: size.height - centerY - h / 2, width: size.width, height: h),
                            withAttributes: attrs)
}

draw("Klimacontrol installieren", font: .systemFont(ofSize: 26, weight: .bold),
     color: NSColor(srgbRed: 0.13, green: 0.14, blue: 0.16, alpha: 1), centerY: 62)
draw("Ziehe Klimacontrol in den Ordner „Programme“.", font: .systemFont(ofSize: 14, weight: .regular),
     color: NSColor(srgbRed: 0.42, green: 0.44, blue: 0.48, alpha: 1), centerY: 96)

// Pfeil zwischen den Symbolen (Symbolmitten bei x 160 und 480, Breite 128 → Lücke von 224 bis 416).
let arrowColor = NSColor(srgbRed: 0.20, green: 0.47, blue: 0.93, alpha: 1)
let y = size.height - 210
let start = CGPoint(x: 250, y: y), tip = CGPoint(x: 390, y: y)
let shaft = NSBezierPath()
shaft.move(to: start)
shaft.line(to: CGPoint(x: tip.x - 14, y: y))
shaft.lineWidth = 6
shaft.lineCapStyle = .round
arrowColor.setStroke()
shaft.stroke()
let head = NSBezierPath()
head.move(to: tip)
head.line(to: CGPoint(x: tip.x - 24, y: y + 15))
head.line(to: CGPoint(x: tip.x - 24, y: y - 15))
head.close()
head.lineJoinStyle = .round
head.lineWidth = 3
arrowColor.setFill()
head.fill()
head.stroke()

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do { try png.write(to: URL(fileURLWithPath: args[1])) } catch {
    FileHandle.standardError.write(Data("Schreiben fehlgeschlagen: \(error.localizedDescription)\n".utf8))
    exit(1)
}
