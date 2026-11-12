// Erzeugt von tools/sync_release_notes.py aus CHANGELOG.md und CHANGELOG.en.md – nicht von Hand ändern.

extension ReleaseNotes {
    static let changelog = #"""
# Changelog

Neueste Version oben; Abschnitte „Hinzugefügt“, „Geändert“, „Behoben“, „Entfernt“; Deutsch, aus Sicht des Nutzers.
Versionen haben vier Stellen, Hauptversion.Funktionen.Fehlerbehebung.Bau: neues Paket ohne Änderung für Nutzer →
`1.0.0.1`, Fehlerbehebung → `1.0.1.0`, Neues → `1.1.0.0`, Änderungen, die Einrichtung oder Daten unbrauchbar machen →
`2.0.0.0`.

## [1.3.0.0] – in Arbeit

### Hinzugefügt
- Fehlercode der Anlage: Jeder Wechsel steht im Protokoll und im Verlauf (neue Spalte „Fehlercode“ im Export).
- Verlauf: Leistung, Temperatur und Außentemperatur stehen in einer Karte mit gemeinsamer Zeitachse.
- Verlauf: Ein farbiges Band unter der Leistung zeigt, wann die Anlage in welchem Modus lief.
- Verbrauch: Wert über jedem Balken und gestrichelte Linie für den Durchschnitt der abgeschlossenen Zeiträume.
- Darstellung: Einstellung „Außentemperatur im Temperaturgraphen zeigen“.
- Die Skala der Solltemperatur zeigt die Raumtemperatur als Marke.
- Windows: Eine beschädigte Einstellungsdatei wird beim Start beiseitegelegt und gemeldet, statt still durch Standardwerte ersetzt zu werden.
- Updates: Einstellungen „Updates automatisch installieren“ und „Nach Updates suchen“ (täglich oder wöchentlich); ohne automatische Installation wird ein geladenes Update erst nach „Jetzt installieren“ installiert.
- Windows: Der Reiter „Darstellung“ zeigt oben eine Vorschau, die Thema, Hell/Dunkel und Größe sofort übernimmt.

### Geändert
- Hauptfenster: Modus und Lüfter sowie Szenen und Timer stehen jeweils in einer gemeinsamen Karte.
- Der Ein/Aus-Knopf ist mit „Ein“ bzw. „Aus“ beschriftet.
- Verlauf: Mittel, Spitze, Verbrauch und Kosten stehen als Zeile unter der Leistung statt in vier Kacheln.
- Verlauf: Soll gestrichelt in der Farbe des Modus, Außentemperatur grau gepunktet und geglättet.
- Verlauf: Leistung und Temperaturen haben auf Mac und Windows dieselben Achsen und Gitterlinien.
- Windows: Das Hauptfenster folgt denselben Regeln für Spalten und Größe wie am Mac; Reiter und gestapelte Spalten entfallen.
- Windows: Beim Lüften sind Solltemperatur und Skala ausgeblendet.
- Ausführliches Protokoll: Der Schalter gilt nur bis zum Beenden der App, ein Hinweis zeigt, solange er an ist.
- Schalter für Funktionen, die die Anlage laut ihren Fähigkeiten nicht hat, sind gesperrt; die Kurzinfo nennt den Grund.

### Behoben
- Verlauf: Beschriftungen unter den Verbrauchsbalken und die letzte Uhrzeit unter den Graphen wurden abgeschnitten.
- Mac: Im Vollbild blieb unter dem Graphen der Außentemperatur eine leere Fläche.
- Mac: Eingeschaltete Knöpfe waren im hellen Modus blass und schwer lesbar, die Karten der Steuerspalte wirkten bei durchscheinendem Fenster dunkel und fast deckend.
- Lässt sich der Verlauf nicht speichern, steht ein Hinweis statt „Noch zu wenig Daten“.
- Mac: Mit eingeschaltetem Beta-Kanal scheiterte jede Suche, solange es keine Vorabversion gab, und stabile Updates blieben aus.
- Mac: Das Menüleisten-Fenster blieb nach dem Ausschalten der Anlage zu hoch und zeigte den Inhalt ohne runde Ecken am unteren Rand.
- Windows: Die Versionshinweise im Update-Fenster waren im dunklen Modus kaum lesbar.
- Englische Oberfläche: Hinweise zur ausgeschalteten Anlage, zur Freigabe „Lokales Netzwerk“ und zum Zeitlimit erschienen teils auf Deutsch oder nur als „not reachable“.
- Einrichtung mit dem Midea-Konto: Eine belegte oder nicht antwortende Anlage wurde als Ablehnung des Tokens gemeldet.
- Sicherung einlesen: Eine unlesbare Szene verwarf still alle Szenen der Sicherung.
- Adresse neu suchen: Eine ungültige gefundene Adresse endete ohne Rückmeldung.
- Mini-Fenster: Bei „Groß angezeigt: Raum“ ohne Raumtemperatur stand „–“ statt der Solltemperatur.
- ⌘↑/⌘↓ (Mac) bzw. Strg+↑/↓ (Windows) verstellten beim Lüften die Solltemperatur.
- Windows: Zahl und Text im Infobereich zeigten beim Lüften ein Soll und rundeten Raumtemperaturen bei x,5 ab.
- iECO und „Leistung begrenzen“ lassen sich wie in der Midea-App nur beim Kühlen einschalten, iECO beim Heizen nur, wenn die Anlage es unterstützt; nimmt die Anlage iECO im aktuellen Modus nicht an, nennt der Hinweis den Modus.
- Technischer Unterbau überarbeitet, zahlreiche kleinere Fehler behoben.

## [1.2.0.0] – 2026-11-08

### Hinzugefügt
- Englische Oberfläche. Bei deutscher Systemsprache bleibt die App deutsch, bei jeder anderen erscheint sie auf Englisch.
- Einstellungen → Allgemein: Auswahl der Sprache (Systemsprache, Deutsch, English). Die Änderung wirkt nach einem Neustart der App.
- Mac: Die Sprache lässt sich auch unter Systemeinstellungen → Allgemein → Sprache & Region → Apps festlegen.
- Einstellungen → Allgemein: Währung des Strompreises frei wählbar, bis zu drei Zeichen, Standard €.
- Mac: Einstellungen → Allgemein → Updates: Vorabversionen (Beta) können bezogen werden, standardmäßig aus.
- Windows: Setup auf Deutsch und Englisch, passend zur Anzeigesprache von Windows.
- Signalton lässt sich im Hauptfenster unter „Weitere Funktionen“ schalten.
- Mac: Das Hauptfenster lässt sich in der Größe ändern und im Vollbild nutzen; im Vollbild erscheinen Verlauf und Diagnose nebeneinander.
- Mac: „Nach Updates suchen …“ meldet auch, wenn keine neue Version vorliegt oder die Suche nicht geklappt hat.

### Geändert
- Zahlen, Uhrzeiten und Datumsangaben folgen den Regionseinstellungen des Systems, zum Beispiel Dezimalpunkt oder 12-Stunden-Format.
- Strompreis bis 1000 je kWh einstellbar, bisher bis 10.
- Verlauf: Der lesbare CSV-Export verwendet die Sprache der Oberfläche. Ältere deutsche Exporte lassen sich weiterhin einlesen.
- Versionshinweise, Protokoll und Lizenzhinweise erscheinen in der Sprache der Oberfläche.
- Darstellung: Themen als Vorschaukacheln, Feinheiten unter „Anpassen“.
- Mac: Ein geladenes Update startet die App nicht mehr sofort neu. Ein Hinweis bietet „Jetzt neu starten“ oder „Später“, spätestens beim Beenden wird installiert.
- Mac: Updates werden vor dem Entpacken auf ihre Signatur geprüft, die Update-Information ist ebenfalls signiert.
- Windows: Der Update-Dialog erscheint in der Sprache der App.
- Technischer Unterbau überarbeitet und optimiert, zahlreiche kleinere Fehler behoben.

### Behoben
- Zahlen mit genau halbem Rest wurden abgerundet (21,25 als 21,2), jetzt kaufmännisch gerundet.
- Fassungen 1.0.x erhielten keine Updates mehr; sie werden jetzt auf die aktuelle Fassung gebracht.

## [1.1.0.0] – 2026-11-07

### Hinzugefügt
- Nach einem Update zeigt Klimacontrol beim nächsten Start, was neu ist.
- Verlauf: Verbrauch und Kosten je Tag, Woche oder Monat als Balkendiagramm.
- Windows: Setup mit Haken „Mit Windows starten“ (vorausgewählt).
- Mac: „Beim Anmelden starten“ ist standardmäßig an, auch nach einem Update. Einmal ausgeschaltet, bleibt es aus.

### Behoben
- Midea-Konto: Die gespeicherte Anmeldung wird bei Netzwerkfehlern nicht mehr verworfen.
- Sicherungsdateien werden immer nur für den eigenen Benutzer lesbar geschrieben.
- Ein per WLAN bereits gesendeter Befehl geht nicht zusätzlich über die Cloud raus.
- Nach einem fehlgeschlagenen Befehl zeigt die App den von der Anlage gemeldeten Stand.
- Timer wiederholen keinen Befehl mehr, wenn die Anlage zwischenzeitlich von Hand geschaltet wurde.
- Moduswechsel schaltet Eco, Turbo und „Außengerät leise“ ab, wenn der neue Modus sie nicht unterstützt.
- „Adresse neu suchen“ und „Sicherung einlesen“ unterscheiden zwischen belegter und nicht erreichbarer Anlage.
- Verlauf-Export: Die doppelte Stunde am Ende der Sommerzeit bleibt beim Wiedereinlesen erhalten.
- Windows: Einstellungen gingen bei jedem Neustart verloren.
- Windows: Uhrzeiten wurden in UTC statt in Ortszeit angezeigt.
- Windows: Besserer Kontrast im hellen Thema, kleinere Fehler behoben.

### Geändert
- „Neu einrichten“ warnt, wenn die Zugangsdaten noch nicht gesichert sind.
- „Nur Cloud“ setzt ein angemeldetes Midea-Konto voraus.
- Mac: DMG mit Installationshinweis.
- Mac: Die Einstellung „Größe“ skaliert auch Knöpfe und Regler.
- Update-Verhalten optimiert.
- Technischer Unterbau überarbeitet und optimiert, zahlreiche kleinere Fehler behoben.

## [1.0.0.0] – 2026-11-05
Erste öffentliche Fassung für Mac und Windows.

### Hinzugefügt
- **Steuerung direkt im WLAN** für die Midea PortaSplit (Protokoll V3), ohne Cloud-Zwang; mit Midea-Konto auch
  unterwegs. „Automatisch“ nimmt zu Hause den direkten Weg und springt sonst über das Midea-Konto ein.
- **Bedienung:** Ein/Aus, Kühlen, Heizen, Trocknen, Lüften, Auto, 16–30 °C, Lüfter stufenlos oder in Stufen, dazu
  Schwenken, Eco, Turbo, Außengerät leise, iECO, Ionisierer, Frostschutz, Reinigung, Anzeige, Signalton und Leistung
  begrenzen.
- **Timer** „Ausschalten in …“ und „Einschalten um …“ mit Mitteilung, ob es geklappt hat; **Szenen** zum Speichern
  und Abrufen von Lieblingseinstellungen.
- **Verlauf** von einer Stunde bis sieben Tage mit Leistung, Temperaturen, Verbrauch und Kosten; Export als CSV.
- **Diagnose** live aus der Anlage: Verdichter, Kältekreis, Lüfter, Filter, Fehlercodes.
- **Einrichtung** in drei Wegen: mit Midea-Konto, mit Zugangsdaten (Token und Schlüssel) oder aus einer Sicherung;
  „Adresse neu suchen“ nach einem Router-Wechsel.
- **Darstellung** mit Themen (Standard, Nacht, Neon, Minimal, Kontrast), Hell/Dunkel, Transparenz, Größe und einem
  „Einfach“-Modus.
- **Updates:** Klimacontrol sucht einmal am Tag bei GitHub nach einer neuen Version und fragt, bevor es sie
  installiert (Einstellungen → Allgemein → Updates, oder „Nach Updates suchen …“). Jedes Update ist signiert und wird
  vor dem Installieren geprüft.
- Mac: Menüleiste mit Schnellsteuerung, schwebendes Mini-Fenster, Tastenkürzel; Installation per **DMG**, signiert
  und von Apple notarisiert.
- Windows: Symbol im Infobereich mit Schnellsteuerung (Strg+Alt+K), Mini-Fenster; Installation per **Setup** ohne
  Administratorrechte, mit Verknüpfung im Startmenü und auf dem Desktop.
  Das Setup ist nicht von Microsoft signiert, darum warnt Windows beim ersten Start („Weitere Informationen“ →
  „Trotzdem ausführen“); die Updates selbst sind signiert und werden geprüft.
"""#

    /// Leer, solange es CHANGELOG.en.md nicht gibt.
    static let changelogEnglish = #"""
# Changelog

Newest version first; sections "Added", "Changed", "Fixed", "Removed"; English, from the user's point of view.
Versions have four parts, major.features.fixes.build. Earlier versions are available in German only.

## [1.3.0.0] – in progress

### Added
- Air conditioner error code: Every change is written to the log and to the history (new column “Error code” in the export).
- History: Power, temperature and outdoor temperature share one card with a common time axis.
- History: A colored band below the power shows when the air conditioner ran in which mode.
- Consumption: Value above each bar and a dashed line for the average of completed periods.
- Appearance: Setting “Show outdoor temperature in the temperature chart”.
- The target temperature scale shows the room temperature as a marker.
- Windows: A damaged settings file is set aside and reported at startup instead of being silently replaced with default values.
- Updates: Settings “Install updates automatically” and “Check for updates” (daily or weekly); without automatic installation, a downloaded update is installed only after “Install now”.
- Windows: The Appearance tab shows a preview at the top that follows theme, light/dark and size immediately.

### Changed
- Main window: Mode and fan, as well as scenes and timers, each share one card.
- The power button is labeled “On” or “Off”.
- History: Average, peak, consumption and cost appear as one line below the power instead of four tiles.
- History: Target dashed in the color of the mode, outdoor temperature dotted gray and smoothed.
- History: Power and temperatures use the same axes and grid lines on Mac and Windows.
- Windows: The main window follows the same rules for columns and size as on the Mac; tabs and stacked columns are gone.
- Windows: In Fan mode, the target temperature and its scale are hidden.
- Detailed log: The switch applies only until the app quits, and a notice shows while it is on.
- Switches for features the air conditioner does not have according to its capabilities are disabled; the tooltip names the reason.

### Fixed
- History: Labels under the consumption bars and the last time under the charts were cut off.
- Mac: In full screen, an empty area remained below the outdoor temperature chart.
- Mac: Switched-on buttons were pale and hard to read in light mode, and the cards of the control column looked dark and nearly opaque in a see-through window.
- If the history cannot be saved, a notice appears instead of “Not enough data yet”.
- Mac: With the beta channel turned on, every check failed while no pre-release existed, and stable updates were not installed.
- Mac: The menu bar window stayed too tall after turning off the air conditioner and showed its content at the bottom without rounded corners.
- Windows: Release notes in the update window were hard to read in dark mode.
- English interface: Notices about a switched-off air conditioner, the Local Network permission and the time limit appeared partly in German or only as “not reachable”.
- Setup with the Midea account: A busy or unresponsive air conditioner was reported as rejecting the token.
- Restore backup: One unreadable scene silently discarded all scenes of the backup.
- Find address again: An invalid address found by the search ended without any feedback.
- Mini window: With the room temperature shown large but not reported, “–” appeared instead of the target temperature.
- ⌘↑/⌘↓ (Mac) and Ctrl+↑/↓ (Windows) changed the target temperature in Fan mode.
- Windows: The number and text in the notification area showed a target in Fan mode and rounded room temperatures ending in .5 down.
- As in the Midea app, iECO and “Limit power” can only be turned on when cooling, iECO when heating only if the air conditioner supports it; if the air conditioner does not accept iECO in the current mode, the notice names the mode.
- Technical foundation reworked, numerous minor bugs fixed.

## [1.2.0.0] – 2026-11-08

### Added
- English user interface. With German as the system language the app stays German, with any other language it appears in English.
- Settings → General: language selection (System language, Deutsch, English). The change takes effect after restarting the app.
- Mac: The language can also be set in System Settings → General → Language & Region → Applications.
- Settings → General: currency of the electricity price can be set freely, up to three characters, default €.
- Mac: Settings → General → Updates: pre-release (beta) versions can be received, off by default.
- Windows: Setup in German and English, matching the Windows display language.
- The beep can be switched on and off in the main window under “More features”.
- Mac: The main window can be resized and used in full screen; in full screen, history and diagnostics appear side by side.
- Mac: “Check for updates…” also reports when no new version is available or the check did not work.

### Changed
- Numbers, times and dates follow the system's regional settings, for example decimal point or 12-hour format.
- Electricity price can be set up to 1000 per kWh, previously up to 10.
- History: The readable CSV export uses the language of the user interface. Older German exports can still be imported.
- Release notes, log and license notices appear in the language of the user interface.
- Appearance: Themes shown as preview tiles, fine-tuning under “Customize”.
- Mac: A downloaded update no longer restarts the app immediately. A notice offers “Restart now” or “Later”; it is installed at the latest when the app quits.
- Mac: Updates are verified against their signature before unpacking; the update information is signed as well.
- Windows: The update dialog appears in the language of the app.
- Technical foundation reworked and optimized, numerous minor bugs fixed.

### Fixed
- Numbers with exactly half a remainder were rounded down (21.25 as 21.2), they are now rounded half away from zero.
- Versions 1.0.x no longer received updates; they are now updated to the current version.
"""#
}
