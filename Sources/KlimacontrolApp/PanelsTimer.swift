import MideaKit
import KlimacontrolCore
import SwiftUI

// Timer: von der App ausgeführt.

struct TimerRow: View, Equatable {
    @Environment(ACController.self) var model
    @Environment(\.klimaTheme) private var theme
    /// Nur Modus (für die Farbe) und Ein/Aus – neue Messwerte rechnen die Zeile nicht neu.
    let mode: OperationalMode
    let power: Bool
    @State private var pickingOnTime = false

    init(state: ACState) {
        mode = state.mode
        power = state.power
    }

    nonisolated static func == (a: TimerRow, b: TimerRow) -> Bool { a.mode == b.mode && a.power == b.power }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer").foregroundStyle(.secondary).accessibilityHidden(true)
            if let off = model.offAt {
                // Nur die Restzeit läuft mit, nicht die ganze Zeile samt Menü und Popover – und nur dann,
                // wenn sich die angezeigte Minute ändert.
                TimelineView(MinuteSteps(end: off)) { _ in
                    chip(model.offTimerChip ?? "", "power") { model.setOffTimer(in: nil) }
                }
            } else if power {
                // Ausgeschaltet gibt es nichts auszuschalten.
                Menu(L.Main.Timer.offMenu) {
                    ForEach(UIOptions.offTimerChoices, id: \.minutes) { choice in
                        Button(choice.label) {
                            model.setOffTimer(in: choice.minutes)
                            TimerNotifier.shared.prepare()
                        }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help(L.Main.Timer.offHelp(requirement: ACController.timerRequirement))
            }
            Spacer()
            if model.onAt != nil {
                // Der Tag („heute“/„morgen“) wechselt um Mitternacht – nur dann neu zeichnen.
                TimelineView(.explicit([Date(), ACController.nextDayStart(after: Date())])) { _ in
                    chip(model.onTimerChip ?? "", "sunrise") { model.setOnTimer(at: nil) }
                }
            } else {
                Button(L.Main.Timer.onButton) { pickingOnTime = true }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $pickingOnTime) {
                        OnTimerPopover(close: { pickingOnTime = false })
                    }
            }
        }
        .font(.callout)
        // Karte und Innenabstand setzt der Aufrufer (gemeinsame Karte mit den Szenen).
    }

    private func chip(_ text: String, _ icon: String, cancel: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Label(text, systemImage: icon).monospacedDigit()
            // Trefferfläche um das kleine Symbol herum vergrößert (sonst ~13 pt).
            Button(action: cancel) { Image(systemName: "xmark.circle.fill").padding(5).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(L.Main.Timer.delete).accessibilityLabel(L.Main.Timer.delete)
        }
        .foregroundStyle(theme.tint(for: mode))
    }
}

/// Uhrzeit wählen; der Tag ergibt sich immer frisch aus „jetzt“: liegt die Uhrzeit heute schon hinter uns, ist
/// morgen gemeint. Kein gespeichertes Datum – ein Tage später geöffnetes Popover bleibt korrekt.
private struct OnTimerPopover: View {
    @Environment(ACController.self) var model
    let close: () -> Void
    /// Nur Stunde und Minute zählen; das Datum dieses Werts wird nie benutzt.
    @State private var time = ACController.defaultOnTime(now: Date())

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker(L.Main.Timer.time, selection: $time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.field)
            // Der Tag steht immer dabei, damit niemand rätselt, ob heute oder morgen gemeint ist.
            TimelineView(.everyMinute) { ctx in
                let at = ACController.nextOccurrence(of: time, after: ctx.date)
                Label(UIText.onTimerPreview(at, now: ctx.date), systemImage: "calendar")
                    .font(.callout.weight(.medium))
            }
            Text(L.Main.Timer.onNote(requirement: ACController.timerRequirement))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L.Common.cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button(L.Main.Timer.set) {
                    model.setOnTimer(at: time)
                    TimerNotifier.shared.prepare()
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14).frame(width: 280)
    }
}

/// Zeitpunkte, an denen sich die gerundete Restzeit (`remaining`) um eine Minute ändert – statt alle 15 s.
private struct MinuteSteps: TimelineSchedule {
    let end: Date

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next: Date? = start
        return AnyIterator {
            guard let current = next else { return nil }
            let left = end.timeIntervalSince(current)
            if left < 30 {
                next = nil // „0 min“ bleibt stehen, bis der Timer auslöst
            } else {
                // Angezeigt wird m = ⌊left/60 + 0,5⌋; auf m − 1 springt es bei left = (m − 0,5) · 60.
                let m = (left / 60 + 0.5).rounded(.down)
                let step = end.addingTimeInterval(-(m - 0.5) * 60 + 0.05)
                next = step > current ? step : current.addingTimeInterval(1)
            }
            return current
        }
    }
}
