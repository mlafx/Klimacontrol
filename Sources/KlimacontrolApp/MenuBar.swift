import AppKit
import MideaKit
import KlimacontrolCore
import SwiftUI

// MARK: - Menüleiste: alle Alltagssteuerungen, Diagnose und Verlauf bleiben im Fenster

/// Inhalt des Menüleisten-Fensters. Liest selbst nichts aus dem Modell – so rechnet eine neue Abfrage nur die
/// Unteransichten neu, deren Werte sich wirklich geändert haben.
struct CompactView: View {
    @Environment(ACController.self) private var model
    // Höhe aus dem Inhalt messen: eine ScrollView hat keine Eigenhöhe, sonst fällt das
    // selbst-dimensionierende Menüleisten-Fenster auf ~0 zusammen (Popover wirkt leer).
    @State private var contentHeight: CGFloat = 420

    var body: some View {
        let size = CGSize(width: 380, height: min(max(contentHeight, 1), 760))
        ScrollView {
            CompactContent()
                .padding(16)
                // Meldet nur echte Höhenänderungen (ganze Punkte), statt bei jedem Layout eine Preference zu setzen.
                .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { contentHeight = $0 }
        }
        .frame(width: size.width, height: size.height)
        .modifier(GlassContainer())
        .focusedSceneValue(\.klimacontrolControls, true)
        .background(VisibilityProbe { model.setUIVisible("menu", $0) })
        .background(MenuBarWindowFitter(size: size))
    }
}

private struct CompactContent: View {
    @Environment(ACController.self) var model

    var body: some View {
        let simple = model.appearance.scope == .simple
        let roomBig = model.appearance.hero == .room
        VStack(alignment: .leading, spacing: 16) {
            if let s = model.state {
                let staleSince = model.uiStaleSince
                // Alte Werte: Statuszeile sagt „Stand HH:MM · nicht aktuell“, Zahl und Knöpfe abgeblendet.
                CompactHeader(name: model.displayName, status: model.staleText ?? model.statusLine,
                              power: s.power, mode: s.mode, stale: staleSince != nil)
                    .equatable()
                if UIText.targetAdjustable(s) {
                    // Lüften hat kein Ziel: kein ±.
                    CompactTarget(target: s.targetTemperature, room: roomBig ? s.indoorTemperature : nil, mode: s.mode,
                                  live: staleSince == nil)
                        .equatable()
                        .staleDimmed(staleSince != nil)
                }
                if !simple { ReadingsStrip(state: s) }
                MaintenanceHint(state: s, compact: true)
                ControlStack(state: s, stale: staleSince != nil, simple: simple, roomShownElsewhere: false)
            } else if model.config == nil {
                Text(L.Menu.noDevice)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            } else {
                StartupView(compact: true)
            }
            if let msg = model.uiMessage {
                // Hinweis „Anlage ausgeschaltet …“ ist kein Fehler – grau statt orange (wie MessageBanner im Fenster).
                // Farbe nur am Symbol, Text in Normalfarbe (Kontrast im hellen Modus); Code klein am Ende.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: model.uiDeviceOff ? "powersleep" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(model.uiDeviceOff ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    MessageText.text(msg).font(.caption)
                        .foregroundStyle(model.uiDeviceOff ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        // Rohtext (Fachwörter) nur im Tooltip, nicht im Haupttext.
                        .help(Localizer.language == .de ? msg.detail ?? "" : msg.text)
                    if model.lastRefreshFailed {
                        Button(UIText.retryButton) { Task { await model.refreshNow() } }
                            .buttonStyle(.bordered).controlSize(.mini)
                    }
                }
            }
            if let note = model.noticeMessage {
                // Hinweis zu einem Befehl – die Verbindung steht, darum ruhig in Grau.
                Label { MessageText.text(note) } icon: { Image(systemName: "info.circle") }
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            CompactFooter()
        }
    }
    // Die Statuszeile kommt aus dem Kern (`ACController.statusLine`) – gleiche Logik wie unter Windows.
}

/// Name, Statuszeile und Ein/Aus – nur neu, wenn sich einer dieser Werte ändert.
private struct CompactHeader: View, Equatable {
    @Environment(ACController.self) var model
    @Environment(\.klimaTheme) private var theme
    let name: String
    let status: String
    let power: Bool
    let mode: OperationalMode
    var stale = false

    nonisolated static func == (a: CompactHeader, b: CompactHeader) -> Bool {
        a.name == b.name && a.status == b.status && a.power == b.power && a.mode == b.mode && a.stale == b.stale
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.headline)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            PowerButton(on: power, tint: stale ? .gray : theme.tint(for: mode)) {
                model.setPower(!power)
            }
        }
    }
}

/// Solltemperatur mit −/+ (bei „Groß angezeigt: Raumtemperatur“ die Raumtemperatur groß, Soll klein darunter).
private struct CompactTarget: View, Equatable {
    @Environment(\.klimaTheme) private var theme
    let target: Double
    /// Raumtemperatur groß zeigen (nil = Solltemperatur groß).
    var room: Double? = nil
    let mode: OperationalMode
    var live = true

    nonisolated static func == (a: CompactTarget, b: CompactTarget) -> Bool {
        a.target == b.target && a.room == b.room && a.mode == b.mode && a.live == b.live
    }

    var body: some View {
        let tint = theme.tint(for: mode)
        TemperatureStepper(target: target) {
            VStack(spacing: 0) {
                Text(room.map { Fmt.temp($0) } ?? Fmt.target(target))
                    .font(HeroLook(theme).font(44))
                    .foregroundStyle(tint)
                    .heroGlow(tint, active: live)
                if room != nil {
                    Text(L.Menu.target(target: Fmt.target(target))).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        }
    }
}

/// „Klimacontrol öffnen“ / „Beenden“ – hängt an keinem Modellwert.
private struct CompactFooter: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack {
            Button(L.Menu.Mac.openApp) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Spacer()
            Button(L.Menu.quit) { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.borderless).font(.callout)
    }
}

// MARK: - Symbol in der Menüleiste

/// Liest Zustand und Darstellung und gibt nur Text, Symbol, Farbe und „dreht“ weiter: Die Menüleiste rendert ihr Bild
/// (`NSStatusItem`) bei jeder Änderung der Beschriftung neu – so nur, wenn sich einer dieser Werte ändert.
struct MenuBarStatusLabel: View {
    @Environment(ACController.self) var model
    @Environment(\.klimaTheme) private var theme

    /// Anlage laut Cloud aus: durchgestrichenes Klimagerät, wo das System das Symbol kennt, sonst „schlafend“.
    private static let deviceOffSymbol: String = {
        let slashed = "air.conditioner.horizontal.slash"
        return NSImage(systemSymbolName: slashed, accessibilityDescription: nil) != nil ? slashed : "moon.zzz"
    }()

    var body: some View {
        icon.modifier(WhatsNewOpener())
    }

    @ViewBuilder private var icon: some View {
        let a = model.appearance
        switch model.uiConnectionState {
        case .deviceOff:
            MenuBarIcon(title: nil, symbol: Self.deviceOffSymbol)
        case .noConnection:
            MenuBarIcon(title: nil, symbol: "exclamationmark.triangle", color: a.menuBarColored ? .orange : nil)
        case .live, .connecting, .notConfigured:
            let s = model.state
            let on = s?.power == true ? s : nil
            let running = on != nil && model.uiConnectionState == .live
            // Lüfter dreht, solange die Anlage läuft – nicht bei „Animationen reduzieren“ bzw. „Bewegung reduzieren“.
            let spin = a.menuBarAnimated && running && theme.motionAllowed
            MenuBarIcon(title: model.menuTitle,
                        symbol: spin ? "fan" : on?.mode.symbol,
                        color: a.menuBarColored && running ? on.map { theme.tint(for: $0.mode) } : nil,
                        spinning: spin)
        }
    }
}

/// Mit Titel: Text + Symbol; ohne Titel nur das Symbol (Standard: Klimagerät). Ohne Farbe und Drehen ein
/// Vorlage-Symbol; farbig bzw. drehend als gerendertes Bild (die Menüleiste zeigt sonst nur Vorlagen).
struct MenuBarIcon: View, Equatable {
    let title: String?
    let symbol: String?
    var color: Color? = nil
    var spinning = false
    @State private var frame = 0

    nonisolated static func == (a: MenuBarIcon, b: MenuBarIcon) -> Bool {
        a.title == b.title && a.symbol == b.symbol && a.color == b.color && a.spinning == b.spinning
    }

    /// 12 Bilder je Umdrehung, 10 je Sekunde (≤ 30 fps): eine Umdrehung in 1,2 s.
    private static let frames = 12

    var body: some View {
        let name = symbol ?? "air.conditioner.horizontal"
        Group {
            if color == nil && !spinning {
                if let title {
                    Label(title, systemImage: name).labelStyle(.titleAndIcon)
                } else {
                    Image(systemName: name)
                }
            } else {
                let image = MenuBarSymbolCache.image(name, color: color, angle: Double(frame) * 360 / Double(Self.frames))
                if let title {
                    Label { Text(title) } icon: { image }.labelStyle(.titleAndIcon)
                } else {
                    image
                }
            }
        }
        .task(id: spinning) {
            frame = 0
            guard spinning else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                frame = (frame + 1) % Self.frames
            }
        }
    }
}

/// Gerenderte Menüleisten-Symbole (farbig und/oder gedreht), zwischengespeichert – je Farbe höchstens 12 Bilder.
@MainActor
enum MenuBarSymbolCache {
    private static var cache: [String: NSImage] = [:]

    static func image(_ symbol: String, color: Color?, angle: Double) -> Image {
        let key = "\(symbol)|\(color.map { "\($0)" } ?? "-")|\(Int(angle))"
        if let hit = cache[key] { return Image(nsImage: hit) }
        if cache.count > 96 { cache.removeAll() }
        let view = Image(systemName: symbol)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(color ?? .black)
            .rotationEffect(.degrees(angle))
            .frame(width: 18, height: 18)
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let img = renderer.nsImage else { return Image(systemName: symbol) }
        // Ohne Farbe (nur Drehen) bleibt es eine Vorlage: die Menüleiste färbt es hell/dunkel passend.
        img.isTemplate = color == nil
        cache[key] = img
        return Image(nsImage: img)
    }
}
