import MideaKit
import KlimacontrolCore
import SwiftUI

/// Protokoll-Reiter. `.task` läuft nur bei sichtbarem Reiter; alle 3 s wird nur der Dateistempel geprüft, gelesen
/// erst bei Änderung, aufbereitet im Hintergrund. Anzeige in Ortszeit (die Datei schreibt UTC), wahlweise ohne
/// DEBUG-Zeilen samt Hex-Folgezeilen; die Datei bleibt unverändert. Neueste Einträge unten.
struct LogSettings: View {
    /// Rohes Dateiende; nil = noch nicht gelesen (nicht schon beim Aufbau lesen: der Startwert wird bei jedem
    /// Neuaufbau ausgewertet).
    @State private var raw: String?
    @State private var text: String?
    @State private var debug = AppLog.debugEnabled
    @AppStorage(SettingsKey.logEventsOnly) private var eventsOnly = true
    @State private var confirmClear = false
    @State private var watch = LogWatch()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(text.map { $0.isEmpty ? L.Settings.Log.empty : $0 } ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .defaultScrollAnchor(.bottom)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Toggle(L.Settings.Log.Detailed.title, isOn: $debug)
                        .onChange(of: debug) { _, v in AppLog.debugEnabled = v; AppLog.write("Ausführliches Protokoll \(v ? "an" : "aus")") }
                    // Ohne Debug gibt es keine DEBUG-Zeilen zum Ausblenden.
                    Toggle(L.Settings.Log.EventsOnly.title, isOn: $eventsOnly)
                        .disabled(!debug)
                        .help(L.Settings.Log.EventsOnly.help)
                        .onChange(of: eventsOnly) { _, _ in reload(force: true) }
                    Spacer()
                    Text(L.Settings.Log.legend).font(.caption).foregroundStyle(.secondary)
                }
                // Standard aus: Das normale Protokoll reicht für die Fehlersuche über Tage; Debug füllt die 5 MB in
                // wenigen Stunden und überschreibt dann die älteren Einträge.
                Text(debug
                     ? L.Settings.Log.Detailed.on
                     : L.Settings.Log.Detailed.off)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L.Settings.Log.refresh) { reload(force: true) }
                Button(L.Settings.Log.Mac.showInFinder) { NSWorkspace.shared.activateFileViewerSelecting([AppLog.url]) }
                Button(L.Settings.Log.Clear.button) { confirmClear = true }
                    .confirmationDialog(L.Settings.Log.Clear.title, isPresented: $confirmClear) {
                        Button(L.Settings.Log.Clear.confirm, role: .destructive) { AppLog.clear(); watch.stamp = nil; raw = ""; text = "" }
                        Button(L.Common.cancel, role: .cancel) {}
                    } message: {
                        Text(L.Settings.Log.Clear.message)
                    }
            }
        }
        .padding(16)
        .task {
            while !Task.isCancelled {
                reload(force: false)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Ohne Debug gibt es nichts auszublenden – dann immer alles zeigen.
    private var filtering: Bool { eventsOnly && debug }

    /// Liest das Protokollende nur bei geändertem Stempel (oder auf Knopfdruck) im Hintergrund; setzt den Text nur,
    /// wenn er anders ist – das Neusetzen eines 300-Zeilen-Texts kostet Layout und Glyphen. Mit „Nur Ereignisse“
    /// werden mehr Zeilen gelesen, damit nach dem Ausblenden der DEBUG-Zeilen noch genug übrig bleibt.
    private func reload(force: Bool) {
        let stamp = LogWatch.Stamp.current()
        guard force || raw == nil || stamp == nil || stamp != watch.stamp else { return }
        guard !watch.reading else { return }
        watch.stamp = stamp
        watch.reading = true
        let only = filtering
        Task {
            let (fresh, shown) = await Task.detached(priority: .utility) {
                let fresh = AppLog.tail(only ? 3000 : 300)
                return (fresh, LogRender.render(fresh, eventsOnly: only))
            }.value
            watch.reading = false
            raw = fresh
            if shown != text { text = shown }
        }
    }
}

/// Aufbereitung des Protokolls – ohne Bindung an den MainActor, damit sie im Hintergrund laufen kann.
enum LogRender {
    /// Zeitstempel in Ortszeit; mit `eventsOnly` fallen DEBUG-Zeilen und ihre Folgezeilen (Hex ohne Zeitstempel) weg.
    /// Höchstens 300 Zeilen, die letzten.
    static func render(_ raw: String, eventsOnly: Bool) -> String {
        let utc = ISO8601DateFormatter()
        let local = DateFormatter()
        local.locale = Fmt.locale
        local.setLocalizedDateFormatFromTemplate("MMddHHmmss")
        var out: [String] = []
        var dropping = false
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            // Zeile mit Zeitstempel: „2026-11-04T18:58:19Z LEVEL Text“
            if line.count > 21, line[line.index(line.startIndex, offsetBy: 19)] == "Z",
               let date = utc.date(from: String(line.prefix(20))) {
                let rest = line.dropFirst(20).drop(while: { $0 == " " })
                dropping = eventsOnly && rest.hasPrefix("DEBUG")
                if !dropping { out.append(local.string(from: date) + " " + String(rest)) }
            } else if !dropping {
                out.append(String(line))
            }
        }
        return out.suffix(300).joined(separator: "\n")
    }
}

/// Merkt sich den letzten Dateistempel, ohne die Ansicht bei jeder Prüfung ungültig zu machen.
private final class LogWatch {
    struct Stamp: Equatable {
        let size: UInt64
        let modified: Date?

        /// Frisch per stat gelesen (kein zwischengespeicherter URL-Wert).
        static func current() -> Stamp? {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: AppLog.url.path) else { return nil }
            return Stamp(size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0, modified: attrs[.modificationDate] as? Date)
        }
    }

    var stamp: Stamp?
    var reading = false
}
