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
                Menu("Ausschalten in …") {
                    ForEach(UIOptions.offTimerChoices, id: \.minutes) { choice in
                        Button(choice.label) {
                            model.setOffTimer(in: choice.minutes)
                            TimerNotifier.shared.prepare()
                        }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Schaltet die Anlage nach der gewählten Zeit aus. " + ACController.timerRequirement)
            }
            Spacer()
            if model.onAt != nil {
                // Der Tag („heute“/„morgen“) wechselt um Mitternacht – nur dann neu zeichnen.
                TimelineView(.explicit([Date(), Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400 + 1)])) { _ in
                    chip(model.onTimerChip ?? "", "sunrise") { model.setOnTimer(at: nil) }
                }
            } else {
                Button("Einschalten um …") { pickingOnTime = true }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $pickingOnTime) {
                        OnTimerPopover(close: { pickingOnTime = false })
                    }
            }
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .klimaCard(radius: 12)
    }

    private func chip(_ text: String, _ icon: String, cancel: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Label(text, systemImage: icon).monospacedDigit()
            // Trefferfläche um das kleine Symbol herum vergrößert (sonst ~13 pt).
            Button(action: cancel) { Image(systemName: "xmark.circle.fill").padding(5).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Timer löschen").accessibilityLabel("Timer löschen")
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
    @State private var time = TimerDay.defaultTime()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker("Uhrzeit", selection: $time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.field)
            // Der Tag steht immer dabei, damit niemand rätselt, ob heute oder morgen gemeint ist.
            TimelineView(.everyMinute) { ctx in
                let at = TimerDay.next(time, after: ctx.date)
                Label("Schaltet \(TimerDay.label(at, now: ctx.date)) um \(TimerDay.clock(at)) ein",
                      systemImage: "calendar")
                    .font(.callout.weight(.medium))
            }
            Text("Mit den zuletzt benutzten Einstellungen. " + ACController.timerRequirement
                 + " Klimacontrol hält den Mac bis dahin wach; ob es geklappt hat, meldet eine Mitteilung.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Abbrechen", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Timer setzen") {
                    model.setOnTimer(at: TimerDay.next(time, after: Date()))
                    TimerNotifier.shared.prepare()
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14).frame(width: 280)
    }
}

/// Tag und Uhrzeit für den Einschalt-Timer.
enum TimerDay {
    /// 7:00 als Vorschlag (nur Stunde/Minute zählen).
    static func defaultTime(_ now: Date = Date()) -> Date {
        Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: now) ?? now
    }

    /// Nächster Zeitpunkt nach `now` mit Stunde und Minute aus `time` (heute, sonst morgen).
    static func next(_ time: Date, after now: Date, calendar: Calendar = .current) -> Date {
        let c = calendar.dateComponents([.hour, .minute], from: time)
        let match = DateComponents(hour: c.hour ?? 7, minute: c.minute ?? 0, second: 0)
        return calendar.nextDate(after: now, matching: match, matchingPolicy: .nextTime) ?? now.addingTimeInterval(86_400)
    }

    /// „heute“, „morgen“ oder Wochentag mit Datum.
    static func label(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "heute" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "morgen"
        }
        return "am " + date.formatted(Date.FormatStyle().weekday(.abbreviated).day().month(.twoDigits).locale(Fmt.locale))
    }

    static func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Fmt.locale))
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
