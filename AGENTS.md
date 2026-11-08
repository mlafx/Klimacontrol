# AGENTS.md – Arbeitsanleitung für KI-Agenten (Claude, Codex u. a.) und Mitwirkende

Klimacontrol ist eine inoffizielle App für **macOS** und **Windows**, die Midea-PortaSplit-Klimaanlagen direkt im
lokalen WLAN steuert (Midea-LAN-Protokoll V3 „8370“, TCP 6444) und optional über die Midea-Cloud. Diese Datei
beschreibt Aufbau, Befehle, Regeln, Verträge und Fallstricke so genau, dass ein Agent ohne Vorwissen sicher daran
arbeiten kann. **Lies Abschnitt 0–5 vollständig, bevor du etwas änderst**; den Rest gezielt nach Aufgabe (Tabelle in 0).

> Gibt es zusätzlich `_privat/AGENTS.md` (nur auf den Rechnern des Autors, nicht im Repo), gelten deren Regeln
> ergänzend – dort stehen die Absprachen zwischen Mac- und Windows-Agent und Hintergrundwissen zum Code. Fehlt der
> Ordner (frischer Klon), ist das in Ordnung: Alles, was zum Bauen und Testen nötig ist, steht im Repo.

---

## 0. Schnellstart und Wegweiser

```bash
tools/test.sh                      # alle Swift-Tests (Mac), ~1–3 min, braucht weder Netz noch Anlage
tools/test.sh --filter SetupTests  # nur eine Testklasse
tools/build_app.sh                 # Mac-App bauen, DMG + ZIP nach dist/mac/ (universal, signiert soweit möglich)
```

Windows: `powershell -ExecutionPolicy Bypass -File tools\build_windows.ps1 -App` (Swift-Kern, DLL, WPF-App, alle Tests).

| Aufgabe | Lies zuerst | Dateien |
|---|---|---|
| Protokoll, Verbindung, Befehle an die Anlage | 6, 5 | `Sources/MideaKit/` |
| Verhalten der App (Abfrage, Timer, Energie, Szenen, Einrichtung) | 7 | `Sources/KlimacontrolCore/` |
| Neue Einstellung / neuer Schalter auf beiden Plattformen | 15.1, 8 | Kern → Bridge → Mac → Windows |
| Mac-Oberfläche | 9, 13 | `Sources/KlimacontrolApp/` |
| Windows-Oberfläche | 10, 8, 13 | `windows/KlimacontrolTray/` |
| Aussehen / Themen | 7.8, 9.3 | `Appearance.swift`, `Theme.swift`, `windows/…/Theme.cs` |
| Texte, Übersetzung, Formate | 13.2, 7.9 | l10n/Localizable.xcstrings, Localizer.swift, FormatProfile.swift, tools/sync_strings.py |
| Verlauf, CSV, Datenbank | 7.6, Anhang B | `History.swift`, `HistoryDB.swift` |
| Tests schreiben oder reparieren | 11 | `Tests/` |
| Version, CHANGELOG, Ausgabe, Signatur | 14 | `tools/`, `CHANGELOG.md` |
| Release durchführen | 14.4, 14.1, 14.2 | `tools/make_release.py`, `tools/build_app.sh` |
| Updates (Sparkle/WinSparkle), Release | 14.1 | `AppUpdate.swift`, `Updater.swift`, `tools/make_release.py` |

---

## 1. Überblick und Architektur

### 1.1 Schichten

```
            ┌───────────────────────────┐
            │  MideaKit                 │  Protokoll, Krypto, Socket, Discovery, Cloud, Schlüsselbund, Log
            └─────────────┬─────────────┘
                          │
            ┌─────────────▼─────────────┐
            │  KlimacontrolCore         │  ACController, SetupFlow, Verlauf, Energie, Timer, Darstellung, Texte
            └──────┬──────────────┬─────┘
                   │              │
     ┌─────────────▼───┐   ┌──────▼──────────────┐
     │ KlimacontrolApp │   │ KlimacontrolBridge  │  C-API kc_* (DLL nur unter Windows)
     │ SwiftUI, macOS  │   └──────┬──────────────┘
     └─────────────────┘          │ P/Invoke, JSON
                           ┌──────▼──────────────┐
                           │ windows/Klimacontrol│  C#/WPF, Infobereich
                           │ Tray (.NET 10)      │
                           └─────────────────────┘
```

Grundsatz: **Jede Oberfläche ist eine dünne Schicht.** Logik, Regeln, Grenzwerte, Standardwerte und Meldungstexte
gehören in den Kern, damit Mac und Windows sich gleich verhalten. Die Mac-App spricht `ACController` direkt an
(`@Observable`), Windows liest JSON-Schnappschüsse über die Bridge und schickt JSON-Befehle zurück.

### 1.2 Bereiche

| Bereich | Pfad | Sprache / Plattform |
|---|---|---|
| Protokoll, Krypto, LAN, Cloud, Gerät | `Sources/MideaKit/` | Swift, alle Plattformen |
| App-Logik ohne Oberfläche | `Sources/KlimacontrolCore/` | Swift, alle Plattformen |
| Mac-App (Fenster, Menüleiste, Mini-Fenster) | `Sources/KlimacontrolApp/` | Swift, nur macOS |
| C-Schnittstelle des Kerns | `Sources/KlimacontrolBridge/` | Swift, überall übersetzt, DLL nur Windows |
| SQLite-Amalgamation (Verlauf unter Windows/Linux) | `Sources/CSQLite/` | C, **nicht ändern** (Herkunft in `Sources/CSQLite/README.md`) |
| Windows-App + Tests | `windows/KlimacontrolTray/`, `windows/KlimacontrolTray.Tests/` | C# / .NET 10 / WPF |
| Swift-Tests | `Tests/MideaKitTests/`, `Tests/KlimacontrolCoreTests/` | XCTest; gemeinsame Daten für Swift und C# in `Tests/Shared/` (Rundungstabelle) |
| Bau- und Hilfsskripte, `VERSION`, App-Symbol | `tools/` | zsh, PowerShell, Python, Swift |
| Text-Katalog (Deutsch, Englisch), daraus `StringsData.swift` | `l10n/Localizable.xcstrings` | JSON (String Catalog), alle Plattformen |
| Versionshinweise, Sicherheitshinweise | `CHANGELOG.md`, `CHANGELOG.en.md`, `SECURITY.md` | Markdown |
| Lizenzhinweise, Screenshots fürs README | `docs/THIRD_PARTY_NOTICES.md`, `docs/screenshots/` | – |
| Bauausgaben | `dist/mac/`, `dist/windows/` (gitignoriert) | – |
| Private Unterlagen | `_privat/` (gitignoriert, nie committen) | – |

### 1.3 Plattformweichen

Im Code stehen Weichen als `#if canImport(CryptoKit)`, `#if canImport(CommonCrypto)`, `#if canImport(Security)`,
`#if os(macOS)` und `#if os(Windows)`. Apple-Plattformen nutzen CryptoKit/CommonCrypto, Security (Schlüsselbund) und
das System-SQLite; Windows/Linux nutzen swift-crypto (`Crypto`, `_CryptoExtras`), die Windows-
Anmeldeinformationsverwaltung und `CSQLite`. In `Package.swift` ist swift-crypto **immer deklariert**
(`exact: "4.5.2"`), aber nur unter Windows/Linux eingebunden – sonst würde der Mac-Build `Package.resolved` umschreiben.

---

## 2. Ordner und Dateien im Einzelnen

### 2.1 `Sources/MideaKit/`

| Datei | Inhalt |
|---|---|
| `Crypto.swift` | `MideaCrypto` (MD5-Signatur, AES-ECB/CBC, SHA256), `AESModes` (ECB/CBC aus Einzelblöcken für swift-crypto), `MideaError` mit `PathFailure` (typisierte Gründe je Weg) |
| `Packet.swift` | `V2Packet` (0x5A5A, Zeitstempel, Geräte-ID), `V3Codec` (0x8370: Handshake, Sitzungsschlüssel, Neusynchronisation) |
| `Commands.swift` | `OperationalMode`, `FanSpeed`, `SwingMode`, `FrameType`, `PropertyId`, `Frame` (Befehlsrahmen 0xAA…, Prüfsumme, CRC8) |
| `Responses.swift` | `ACState` (Zustand), `Response` (Antworten 0xC0, 0xB5, 0xB0/0xB1, Gruppen), `DeviceTimer` |
| `Diagnostics.swift` | `Diagnostics` (Verdichter, Strom, Spannung, T1–T4, TP, EEV, Lüfter, Abtauen, Filter, Fehlercode) |
| `Socket.swift` | `NetSocket`: blockierende TCP-/UDP-Sockets (BSD-Sockets bzw. Winsock), Zeitlimits |
| `LANClient.swift` | eine LAN-Verbindung: Verbinden, Handshake, Senden/Empfangen, Wiederholung |
| `Transport.swift` | `FrameTransport` (Protokoll), `ConnectionMode` (auto/lan/cloud), `ConnectionPath`, `AutoTransport` (Wegwahl mit Sperren) |
| `CloudControl.swift` | `MideaCloudSession` (actor, Anmeldung + Rückzug), `CloudControlClient`, `CloudTransport` (Befehle über die Cloud) |
| `Cloud.swift` | `MideaCloud` (Token-Abruf, Gerätelisten), `SmartHomeClient` (MSmartHome/meiju), `NetHomePlusClient` (Rückfall) |
| `Discovery.swift` | `Discovery.scan` (Broadcast/Unicast), `Discovery.find(deviceId:)`, `DiscoveredDevice` |
| `Keychain.swift` | `KeychainStore`, `SystemKeychain`, `InMemoryKeychain`, `SecretStore`, `CloudKeychain`, `CloudSessionStore` |
| `PortaSplitDevice.swift` | `DeviceConfig` (device.json, Sicherung), `PortaSplitDevice` (alles, was man mit der Anlage tun kann), `nearestRate` |
| `Scene.swift` | `ACScene` (Szenen, szenen.json) |
| `Log.swift` | `AppLog` (Protokoll, Schwärzen, Rotation), `TestEnvironment` (erkennt Testprozesse) |
| `LogText.swift` | `LogText.t(Schlüssel, deutscher Text, Platzhalter)`: Haken für Protokollzeilen und Fehlertexte aus MideaKit; ohne vom Kern installierten Übersetzer gilt der deutsche Text (7.9) |

`PortaSplitDevice` heißt bewusst so: Der Name bezeichnet das Gerät, nicht die App.

### 2.2 `Sources/KlimacontrolCore/`

| Datei | Inhalt |
|---|---|
| `ACController.swift` | Herzstück: nur der Speicher (nach Bereichen), `init(appVersion:dependencies:autostart:)` plus Komfort-Init, `stop()`, `ConnectionState` |
| `ACController+Preferences.swift` | Einstellungen, Sichtbarkeit der Fenster, Takt |
| `ACController+Status.swift` | Verbindungszustand, `message`/`messageDetail`, Hinweise (`noticeMessage` als `UserMessage`, `notice` = ganzer Satz), Startanzeige |
| `ACController+Session.swift` | Einrichtung übernehmen bzw. wechseln (`SetupSink`), Neu einrichten |
| `ACController+Polling.swift` | Abfrage-Schleife, Schnellmodus |
| `ACController+Commands.swift` | `perform` mit `CommandOutcome`, `send`, `debounced(DebounceKey)`, Stellbefehle |
| `ACController+Backup.swift` | Sicherung einlesen (`checkExclusively`) und sichern |
| `ACController+Cloud.swift` | Midea-Konto anmelden/abmelden |
| `ACController+AddressRecovery.swift` | Adresse neu suchen, automatische Suche (`RelocationTrigger`) |
| `CoreDependencies.swift` | Abhängigkeiten: Einstellungen, Ablage, Plattform, Konto, Gerätebau, Uhr (`now`) |
| `CredentialProbe.swift` | eine Prüfung der Zugangsdaten (Einrichtung, Sicherung, Adresse neu suchen), Ergebnis `CredentialCheck`: angenommen · abgelehnt · belegt · keine Antwort |
| `ACController+UI.swift` | Bedienlogik für Oberflächen: Ein/Aus, Modus, Temperatur, Lüfter-Zonen („Leise außen“/Turbo), Zielzeile/Statuszeile |
| `ACController+Timers.swift` | App-Timer „Ausschalten in …“ / „Einschalten um …“, Ergebnis-Mitteilungen, Schlafschutz |
| `ACController+Energy.swift` | Verbrauch heute, Kosten/h, Plausibilität des Zählers |
| `ACController+Scenes.swift` | Szenen anwenden, speichern, löschen |
| `ACController+Appearance.swift` | Darstellung setzen, Thema anwenden, zurücksetzen |
| `ACDevice.swift` | Protokoll `ACDevice` (Abstraktion von `PortaSplitDevice` für Tests), `CloudAccountStore` |
| `SetupFlow.swift`, `SetupFlow+Manual.swift` | Einrichtungsassistent: Weg wählen, Suche (WLAN, Subnetz, Cloud), Konto, Zugangsdaten prüfen; spricht den Kern nur über `SetupSink` an |
| `History.swift` | `HistorySample`, `HistoryLog` (CSV), `HistoryStore` (Fassade für Oberflächen) |
| `HistoryDB.swift` | `HistoryDB`: verlauf.sqlite, Einfügen, Ausdünnen, Statistik, Import/Export |
| `HistoryRow.swift` | `HistoryColumn` (einzige Spaltentabelle: Kopfzeilen, Schema, Export, Import), `HistoryRow`, `HistoryValue` |
| `HistoryCSV.swift` | Kopfzeilen, Zeitformate, doppelte Stunde am Ende der Sommerzeit, `HistoryCSVReader` |
| `HistorySQLite.swift` | `SQLiteConnection`, `SQLStatement`, `HistoryDBError`; einzige Weiche SQLite3/CSQLite |
| `HistoryEnergy.swift` | Verbrauch je Tag/Woche/Monat (`EnergyPeriodKind`, `EnergyPeriod`, `HistoryDB.energyPeriods`): Zählerstände an den Grenzen, Rückfall auf Messwerte |
| `Appearance.swift` | `Appearance` (alle Darstellungswerte, Themen, robustes Decoding) |
| `Fmt.swift` | `Fmt` (Zahlen, Zeiten, Einheiten auf Deutsch), `UserMessage` (Meldungstexte) |
| `MainWindowLayout.swift` | Mac-Hauptfenster als reine Rechnung (`MainWindowLayout`, `MainWindowFrame`): Spaltenbreiten und Verteilung, „passt nicht“-Regel, Mindesthöhe je Größe, Graphenhöhen, Rahmen beim Ein-/Ausblenden der Spalten (laufen auch unter Windows) |
| `UIOptions.swift` | Anzeige-Katalog: Auswahllisten, Grenzen, Standardwerte, Gültigkeit je Modus (`availability`), Lüfter-Kopfzeile, Verlaufs-Zeiträume und Lückenschwelle |
| `UIText.swift` | Anzeige-Katalog: Rückfragen (`ConfirmPrompt`, `ForgetPrompt` für „Neu einrichten“ mit drei Knöpfen), Ergebnismeldungen (`ResultMessage`), feste Texte, Cloud-Ordner-Prüfung, `HostWords` (Mac/Windows) |
| `UIEnergy.swift` | Anzeige-Katalog des Verbrauchs: Arten und Anzahl (`UIOptions.energyKinds`), Beschriftungen, Kurzinfos, Kosten, Summe |
| `ACController+DisplayText.swift` | Anzeigetexte aus dem Zustand: Verbindungszeile, große Zahl, Kosten, Menüleisten-Titel, Timer-Chips, Startwerte (zeitabhängige auch mit `now:`) |
| `Platform.swift` | `SettingsStore`, `SettingsKey`, `CorePaths`, `PlatformServices`/`FoundationPlatform` (Schlafschutz, Papierkorb) |
| `ThirdPartyNotices.swift` | Lizenztexte für den Reiter „Lizenzen“ (die Lizenztexte selbst englisch; Verwendung, Plattform und Markenhinweis aus dem Katalog `notices.*` in der Sprache der Oberfläche; der deutsche Text muss `docs/THIRD_PARTY_NOTICES.md` wörtlich entsprechen) |
| `LoginItemDefault.swift` | Regel „Beim Anmelden starten“ als Standard: einmalig beim ersten Start aus einem Programme-Ordner (auch nach Updates), nie aus DMG/Build-Ordner |
| `ReleaseNotes.swift`, `ReleaseNotesData.swift`, `ACController+WhatsNew.swift` | „Neu in dieser Version“: eingebetteter CHANGELOG (`ReleaseNotesData.swift`, erzeugt von `tools/sync_release_notes.py`), Zerlegen und Plattformfilter, Regel `WhatsNew.pending`, Merker `lastSeenVersion`; deutsch und englisch (`CHANGELOG.en.md`, Rückfall deutsch mit Hinweis) |
| `AppUpdate.swift` | Updates: Repository, Appcast-Adressen für Mac und Windows, Standard-Suchintervall (täglich) |
| `Localizer.swift` | Sprache des Prozesses (`AppLanguage`, `LanguageChoice`), einmal festgelegt; Texte, Platzhalter, Mehrzahl, Rückfall Englisch, Pseudo-Sprache, Test-Haken; `text(_:language:)` holt einen Text in einer bestimmten Sprache (CSV-Import beider Sprachen, Test-Haken); Protokollzeilen folgen der Sprache der Oberfläche |
| `DisplayNames.swift` | Anzeigenamen für Typen aus MideaKit (Modus, Lüfter, Weg, Szene; Datumswörter `DateWords`), damit die Typen in MideaKit für Datenbank und CSV stabil deutsch bleiben (`title`/`fanTitle`/`summaryText` statt `label`/`summary`) |
| `StringsData.swift` | erzeugt von `tools/sync_strings.py`: eingebetteter Katalog und typisierte Schlüssel `L.…` – nicht von Hand ändern |
| `FormatProfile.swift` | Zahlen- und Zeitformate (Dezimal-/Tausenderzeichen, 12/24 h, Tag/Monat) aus den Regionseinstellungen; Standard de-DE |
| `AppVersion.swift` | Versionsnummer mit Beta-Kennung (`1.2.0.0b1`), Vergleich für „Neu in …“ und Tests |

### 2.3 `Sources/KlimacontrolApp/` (nur macOS)

| Datei | Inhalt |
|---|---|
| `KlimacontrolApp.swift` | `@main`, Szenen (Hauptfenster, Menüleiste `MenuBarExtra`, Mini-Fenster `id: "mini"`, Einstellungen), `AppDelegate` (Rückfrage beim Beenden mit Timern), `TimerNotifier` (Mitteilungen der Timer) |
| `AppCommands.swift` | Menüs „Anlage“/„Darstellung“ mit den Tastenkürzeln (nur aktiv in Haupt- und Menüleisten-Fenster) |
| `FileDialogs.swift` | Dateidialoge und Hinweisfenster: Sicherung einlesen/sichern, Verlauf exportieren, Abschluss der Einrichtung, Warnung vor Cloud-Ordnern |
| `ContentView.swift` | Hauptfenster: `ColumnsLayout` (Spalten Verlauf · Steuerung · Diagnose nach `MainWindowLayout`), scrollende Steuerspalte mit angeheftetem Banner/Fußzeile, `ControlStack` (Bedienblock, auch im Menüleisten-Fenster), „Mehr …“, Effekt-Hintergrund |
| `Hero.swift` | Kopf: große Zahl, `TemperatureStepper` (−/+), Verbindungszeile, Aus-/Lüften-Anzeige, Kennzahlen, Ein/Aus, Mini-Fenster-Knopf |
| `Startup.swift` | Startanzeige bis zur ersten Antwort (zuletzt bekannte Werte, Schritte) |
| `Controls.swift` | Bedienelemente Modus und Lüfter mit Zonen |
| `ComfortSection.swift` | Komfort-Kacheln, weitere Funktionen, Leistung begrenzen (gemeinsamer Schalter `switchButton`) |
| `ScenesSection.swift` | Szenen anwenden, sichern, löschen |
| `MenuBar.swift` | Menüleisten-Fenster und Menüleisten-Symbol |
| `Messages.swift` | Fehler- und Hinweisbanner (Code klein am Ende), „Adresse neu suchen“-Hinweis |
| `WindowSupport.swift` | Fensterhelfer (Sichtbarkeit, `WindowRef` mit Rahmenlogik beim Ein-/Ausblenden der Spalten, Vollbild-Zustand, Vordergrund), Fokuswert der Menü-Kürzel |
| `Charts.swift` | Graphen (Swift Charts) für Leistung und Temperatur |
| `EnergyChart.swift` | Abschnitt „Verbrauch“ unter den Graphen: Balken je Tag/Woche/Monat, liest im Hintergrund höchstens alle 10 min |
| `Theme.swift` | `ThemeStyle`, `\.klimaTheme`, `.klimaCard`, `.klimaGlow`, `GlassContainer`, Farben und Symbole je Modus, `LivelyBackground`, `WeatherEffect` |
| `Panels.swift` | Fußzeile (Verlauf · Aktualisieren/Einstellungen · Diagnose) und gemeinsame Bausteine (Abschnittstitel, alte Werte) |
| `PanelsSettings.swift` | Einstellungsfenster mit Reitern Allgemein · Darstellung · Verbindung · Anlage · Protokoll · Lizenzen |
| `PanelsAppearance.swift` | Reiter „Darstellung“ |
| `PanelsDevice.swift` | Reiter „Anlage“ (Sicherung, Adresse neu suchen, Neu einrichten) |
| `PanelsDiagnostics.swift` | Diagnose-Spalte |
| `PanelsLog.swift` | Reiter „Protokoll“ |
| `PanelsTimer.swift` | Timer-Bedienung |
| `Setup.swift` | Einrichtungsassistent (Oberfläche zu `SetupFlow`) |
| `Notices.swift` | Reiter „Lizenzen“ |
| `Updater.swift` | `AppUpdater`: Hülle um Sparkle (`SPUStandardUpdaterController`), nur im fertigen Bundle aktiv; Hinweis „Jetzt neu starten · Später“, Beta-Kanal |
| `AppRestart.swift` | Neustart der App (Sprachwechsel, geladenes Update) ohne Beenden-Rückfrage, Sprachwahl in `AppleLanguages` der App |
| `WhatsNew.swift` | Fenster „Neu in dieser Version“ |

### 2.4 `Sources/KlimacontrolBridge/`

| Datei | Inhalt |
|---|---|
| `Bridge.swift` | C-Einstiege `kc_*`, globale Zustände, Kodieren, `kc_set_locale`, `kc_strings_json` |
| `BridgeSnapshot.swift` | Schnappschuss-Datenobjekte, Abbildung aus dem Kern, Beobachtung (`kc_state_rev`) |
| `BridgeCommands.swift` | Befehlstabelle (`.device` braucht eine eingerichtete Anlage, `.always` nicht), gruppiert wie 8.3 |
| `BridgeArgs.swift` | Parameter (`JSONValue`, `CommandArgs`, strenge Typen), Meldungen |
| `BridgeJobs.swift` | lange Aufträge (`BridgeJob`: Zähler und Ergebnis, z. B. `loginSeq`/`exportSeq`) |
| `BridgeDisplay.swift` | Anzeige-Katalog im Schnappschuss: `options`, `availability`, fertige Anzeigetexte aus dem Kern |
| `BridgeEnergy.swift` | `kc_energy_json`: Verbrauch je Zeitraum mit fertigen Texten |
| `WindowsTimeZone.swift` | nur Windows: setzt in `kc_init` die Standardzone aus der Windows-Zone (über ICU), weil `TimeZone.current` dort GMT liefert |

Vertrag in Abschnitt 8.

### 2.5 `windows/`

| Pfad | Inhalt |
|---|---|
| `KlimacontrolTray/Native.cs` | P/Invoke auf `res\KlimacontrolBridge.dll`, `ExpectedApi` |
| `KlimacontrolTray/Localization.cs` | `L`: Texte der Oberfläche aus dem Katalog des Kerns (`kc_strings_json`), `{l:T …}` in XAML |
| `KlimacontrolTray/Formats.cs` | C#-Spiegel von `FormatProfile`: Zahlen, Uhrzeit, Datum nach den Regionseinstellungen, Rundung wie Swift (`Tests/Shared/rounding-table.json`) |
| `KlimacontrolTray/StartupText.cs` | Texte vor dem Laden des Katalogs (Startfehler), je Text Deutsch/Englisch nach der Anzeigesprache von Windows |
| `KlimacontrolTray/Core.cs` | Brücken-Hülle: Start, Pumpe (`kc_pump` ~30 ms), Prüfung `kc_api_version`, Befehle |
| `KlimacontrolTray/Model.cs` | C#-Abbild des JSON-Schnappschusses (inkl. `options`/`availability` des Anzeige-Katalogs) |
| `KlimacontrolTray/BridgeCommands.cs` | `Cmd`: alle Befehlsnamen als Konstanten (gegen die Bridge geprüft) |
| `KlimacontrolTray/MainWindow.*`, `ControlPanel.*`, `ChartsPanel.*`, `DiagnosticsPanel.*`, `ScenesSection.*`, `TimerRow.*` | Hauptfenster und seine Teile |
| `KlimacontrolTray/FlyoutWindow.*`, `TrayIcon.cs`, `NotifyArea.cs`, `Icons.cs` | Schnellsteuerung am Infobereich und Symbol |
| `KlimacontrolTray/MiniWindow.*` | Mini-Fenster |
| `KlimacontrolTray/SettingsWindow.*` | Einstellungen (gleiche Reiter wie am Mac), je Reiter eine partial-Datei (`SettingsWindow.General.cs` …), `SettingsTab` |
| `KlimacontrolTray/Setup*.xaml*`, `SetupParts.cs`, `SetupStyles.xaml` | Einrichtungsassistent |
| `KlimacontrolTray/ConnectingView.*` | Anzeige „verbindet …“ beim Start |
| `KlimacontrolTray/Appearance.cs`, `Theme.cs`, `Backdrop.cs`, `AmbientLayer.cs`, `Surface.cs`, `SizeScale.cs`, `Layout.cs` | Darstellung (Mica/Acrylic, Themen, Größen, Effekte) |
| `KlimacontrolTray/Prefs.cs`, `Shortcuts.cs`, `Dialogs.cs`, `DialogWindow.cs`, `ClickCheckBox.cs` | Fenster-Einstellungen, Tastenkürzel (Strg+Alt+K), Dialoge, Haken mit Click auch per Sprachausgabe |
| `KlimacontrolTray/Updates.cs` | WinSparkle (Updates): Feed und Intervall aus dem Kern, Schlüssel aus `tools/UPDATE_PUBLIC_KEY`, nur bei Setup-Installation aktiv; `KLIMACONTROL_UPDATE_TEST_FEED` (nur `http://127.0.0.1:<port>/…`) biegt den Feed zum Prüfen um (`TestFeedOverride`) |
| `KlimacontrolTray/Klimacontrol.ico` | Programmsymbol (aus `tools/AppIcon.icns`, `tools/make_ico.ps1`) |
| `installer/Klimacontrol.iss` | Setup (Inno Setup 6): ohne Administratorrechte nach `%LOCALAPPDATA%\Programs\Klimacontrol`, Startmenü und Desktop |
| `KlimacontrolTray.Tests/` | `CoreTests`, `LayoutTests`, `ThemeTests`, `AppearanceTextTests`, `LocalizationTests`, `UpdatesTests` (Test-Feed nur Loopback), `VertragTests` + `Vertrag/bridge-muster.json` |

### 2.6 `tools/`

| Datei | Zweck |
|---|---|
| `VERSION` | einzige Quelle der Versionsnummer (auch für Windows: `KlimacontrolTray.csproj` liest sie) |
| `test.sh` | Swift-Tests am Mac (Scratch-Pfad außerhalb des Projekts, Protokoll in Temp-Ordner) |
| `build_app.sh` | Mac-App universal bauen, Sparkle einbetten, signieren, optional notarisieren, DMG + ZIP; `--no-test`, `--beta <n>` (Version `<VERSION>b<n>`), `--out <Ordner>` (Probebau statt `dist/mac`); schreibt die zweisprachigen `InfoPlist.strings` (`de.lproj`/`en.lproj`) und `CFBundleLocalizations` |
| `make_release.py` | Release-Ordner `releases/v<Version>/` bzw. Beta `releases/v<Version>b<n>/` (`--beta <n>`): Pakete, Update-Dateien (`updateinfo-mac.xml`, `-win.xml`, `-mac-beta.xml` nur bei `--beta`, als letzter Schritt mit dem Update-Schlüssel signiert und geprüft), Prüfsummen, Release-Text (deutsch und englisch); `--publish` legt das GitHub-Release an, `--check-published` prüft die veröffentlichten Adressen (liest nur), `--rollback <kaputt> <vorige> [--execute]` ist die Notbremse |
| `test_make_release.py` | Selbsttest für `make_release.py` mit Probedateien und nachgebildetem `sign_update` (`python3 -I tools/test_make_release.py`; läuft auch in `ReleaseScriptTests`) |
| `update_test_feed.py` | lokale, signierte Update-Datei zum Prüfen der Updates vor dem Release (Abschnitt 14.1); `--serve-only <Ordner>` liefert einen vorhandenen Ordner nur aus |
| `UPDATE_PUBLIC_KEY` | öffentlicher EdDSA-Schlüssel der Updates (Mac: Info.plist, Windows: WinSparkle) |
| `update_test_feed_win.py` | lokale, mit dem Update-Schlüssel signierte `updateinfo-win.xml` samt Setup für Windows-Updates (nur 127.0.0.1; `--unsigned`, `--bad-signature`, `--serve`, `--selftest`); Aufruf im Kopf des Skripts, Abschnitt 14.1 |
| `check_windows_upgrade.ps1` | Windows, nur lesend: Zustand einer Setup-Installation vor und nach einem Update festhalten und vergleichen (D3/2); **nur ASCII** |
| `build_windows.ps1` | Windows: Swift-Kern + DLL + WPF-App bauen, alle Tests, optional ZIP, Setup, Installation; **nur ASCII** (PowerShell 5.1) |
| `make_ico.ps1` | Windows-Programmsymbol `Klimacontrol.ico` aus `AppIcon.icns` erzeugen |
| `make_vectors.py` | Testvektoren aus msmart-ng erzeugen |
| `query_msmart.py` | Vergleichsabfrage mit msmart-ng (Fehlersuche im Protokoll; spricht die echte Anlage an – nur lesend benutzen) |
| `make_icon.swift`, `AppIcon.icns` | App-Symbol erzeugen bzw. fertiges Symbol |
| `make_dmg.sh`, `dmg_settings.py`, `make_dmg_background.swift` | Installations-DMG (`build_app.sh` ruft `make_dmg.sh`): Hintergrund mit Titel, Anleitung und Pfeil zeichnen, Finder-Ansicht mit **dmgbuild** schreiben; `dmg_requirements.txt` legt Versionen und Prüfsummen fest (pip `--require-hashes`) |
| `check_traces.py` | Spurensuche im fertigen Paket (Benutzer-, Rechnernamen, Pfade), von `build_app.sh` aufgerufen |
| `sync_strings.py` | prüft `l10n/Localizable.xcstrings`, schreibt ihn sortiert zurück und erzeugt `StringsData.swift`; `--check`, `--add` (einfachen Text anlegen), `--merge-parts` (Katalog-Teile zusammenführen, siehe 13.2) |
| `sync_release_notes.py` | bettet `CHANGELOG.md` (und `CHANGELOG.en.md`, falls vorhanden) in `ReleaseNotesData.swift` ein; `--check` vergleicht nur (`test.sh` und `build_app.sh` brechen bei veraltetem Stand ab, ebenso bei `sync_strings.py --check`) |

---

## 3. Werkzeuge, Befehle, Umgebung

### 3.1 Voraussetzungen

- **Swift 6.4 oder neuer.** Am Mac heißt das **Xcode 27 oder neuer** (Swift 6.4 kommt mit Xcode 27; Laufzeitziel
  bleibt macOS 15, gebaut wird mit dem neuesten SDK, weil Liquid-Glass-APIs hinter `#available(macOS 26, *)` stehen).
- Windows: Swift-Toolchain 6.4+ für Windows und das **.NET 10 SDK** (`winget install Microsoft.DotNet.SDK.10`).
- Sprachmodus **Swift 6** (`swiftLanguageModes: [.v6]`), Upcoming-Features `ExistentialAny` und
  `MemberImportVisibility` in jedem Swift-Ziel. Nur Swift Package Manager, **kein Xcode-Projekt**, kein
  `unsafeFlags` (sonst nicht als Abhängigkeit nutzbar), kein `InternalImportsByDefault`.
- `.treatAllWarnings(as: .error)` (SE-0480) in jedem Swift-Ziel: Warnungen brechen den Bau (nicht CSQLite).
- Plattformen in `Package.swift`: macOS 15, iOS 18 (wegen `Mutex` aus Synchronization).

### 3.2 Befehle

| Zweck | Befehl |
|---|---|
| Alle Tests (Mac) | `tools/test.sh` (Argumente gehen an `swift test`, z. B. `--filter TransportTests`, `--skip-build`) |
| Nur bauen inkl. Tests | `swift build --build-tests --scratch-path ~/Library/Caches/Klimacontrol-build` |
| Mac-App bauen | `tools/build_app.sh [--no-test] [--beta <n>] [--out <Ordner>]` (führt vorher alle Tests aus, wie unter Windows) → App in `<Build-Ordner>/app/`, nach `dist/mac/`: `Klimacontrol-<Version>-mac.dmg`, `…-mac.zip`, `LIESMICH.txt` |
| Release vorbereiten | `python3 tools/make_release.py [--beta <n>] [--key-file <Datei>] [--publish]` → `releases/v<Version>[b<n>]/`; Selbsttest `python3 -I tools/test_make_release.py` |
| … und notarisieren | `KLIMACONTROL_NOTARY_PROFILE=<Profil> tools/build_app.sh` (nur mit „Developer ID Application“) |
| Windows bauen + testen | `powershell -ExecutionPolicy Bypass -File tools\build_windows.ps1 [-Release] [-NoTest] [-App] [-Zip] [-Setup] [-Install] [-Shortcut]` |
| Testvektoren neu erzeugen | `python3 tools/make_vectors.py Tests/MideaKitTests/vectors.json` (msmart-ng nötig) |
| App am Mac starten | `open ~/Library/Caches/Klimacontrol-build/app/Klimacontrol.app` (nach `tools/build_app.sh`) |

Schalter von `build_windows.ps1`: `-Release` (optimiert), `-NoTest` (Tests überspringen), `-App` (WPF-App nach
`dist\windows\Klimacontrol\`), `-Zip` (daneben `Klimacontrol-Windows-<Version>.zip` und das Setup), `-Setup`
(`Klimacontrol-Windows-<Version>-Setup.exe`, braucht Inno Setup 6), `-Install` (Kopie nach
`-Dest`, Standard `%USERPROFILE%\Klimacontrol` – nie aus einem Cloud-Ordner starten), `-Shortcut` (Startmenü-Eintrag).

### 3.3 Build-Ordner – wichtigster Fallstrick

**Nie ein nacktes `swift build`/`swift test` im Projektordner**, wenn dieser in einem Cloud-Sync-Ordner liegt
(OneDrive & Co. scheitern an den SwiftPM-Metadaten: „couldn't be saved“). Die Skripte bauen in
`~/Library/Caches/Klimacontrol-build` (änderbar mit `KLIMACONTROL_SCRATCH`), unter Windows in
`%LOCALAPPDATA%\Klimacontrol-build`. Für eigene Läufe immer `--scratch-path <Pfad außerhalb des Projekts>`.

Am Rechner des Autors ist `.build` ein **Symlink** auf den Cache-Ordner – nicht löschen, nicht durch einen Ordner
ersetzen. `tools/build_app.sh` bricht ab, wenn `.build` ein echter Ordner ist; fehlt `.build` ganz (frischer Klon),
baut es trotzdem. Keine `.swiftpm/`-, `*.xcodeproj`- oder sonstigen Werkzeug-Ordner im Projekt anlegen.

### 3.4 Umgebungsvariablen

| Variable | Wirkung |
|---|---|
| `KLIMACONTROL_SCRATCH` | Build-Ordner für `test.sh`/`build_app.sh` |
| `KLIMACONTROL_LOG_DIR` | Ordner fürs Protokoll (`test.sh` setzt einen frischen Temp-Ordner) |
| `KLIMACONTROL_KEYCHAIN=memory` | Schlüsselbund nur im Speicher (auch außerhalb von Tests nutzbar) |
| `KLIMACONTROL_REAL_SECRETS=1` | Tests mit echtem Schlüsselbund – **nur bewusst**, nie dauerhaft setzen |
| `KLIMACONTROL_LIVE_SCAN=1` | Live-Suche im echten WLAN in den Tests – **nur bewusst**, nie dauerhaft setzen |
| `KLIMACONTROL_SIGN_IDENTITY` | Signatur-Identität für `build_app.sh` (`-` = ad hoc) |
| `KLIMACONTROL_NOTARY_PROFILE` | notarytool-Profil im Schlüsselbund → `build_app.sh` notarisiert und heftet das Ticket an |
| `KLIMACONTROL_PSEUDO=1` | Pseudo-Sprache (Testsprache, 13.2) statt Deutsch/Englisch – nur zum Prüfen der Oberfläche |
| `KLIMACONTROL_CULTURE` | Windows: Kultur (z. B. `en-US`) für Formate und Anzeigesprache statt der Windows-Einstellung – nur zum Prüfen; ungültige Werte werden ignoriert |
| `KLIMACONTROL_UPDATE_TEST_FEED` | Update-Datei umleiten, nur `http://127.0.0.1:<port>/…` (sonst wirkungslos, `AppUpdate.testFeedOverride`): Windows für WinSparkle, Mac ab 1.2.0.0 für Sparkle auch im Beta-Kanal (Start mit `open --env …`) – nur zum Prüfen der Updates (14.1), **nie dauerhaft setzen** |

---

## 4. Pflicht vor „fertig“ (Definition of Done)

1. `tools/test.sh` grün (Mac) bzw. `tools\build_windows.ps1` grün (Windows: Swift- **und** C#-Tests).
2. Build **ohne Warnungen** (Sprachmodus 6). Neue Warnungen gelten in diesem Projekt als Fehler (auch in C#: `TreatWarningsAsErrors` in beiden `.csproj`). Ausnahme: Warnungen
   aus `Sources/CSQLite/` unter Windows/Linux werden hingenommen.
3. `CHANGELOG.md` im Abschnitt der laufenden Entwicklungsversion ergänzt (Abschnitt 14). Ohne CHANGELOG-Eintrag ist
   nichts fertig. `tools/VERSION` **nicht** hochzählen – das geschieht nur bei der Release-Freigabe durch den Autor.
4. Bei Oberflächenänderungen: App bauen, starten und die Änderung tatsächlich ansehen (Screenshot) – ohne die Anlage
   zu verstellen. Beide Themen-Extreme mitprüfen (Standard und Kontrast, hell und dunkel), wenn Farben betroffen sind.
5. Betrifft die Änderung Verhalten, Texte oder Optionen: **beide Plattformen** angleichen oder ausdrücklich als offen
   für die andere Plattform im CHANGELOG/Übergabe vermerken. Neue oder geänderte Texte stehen im Katalog in beiden Sprachen
   (`tools/sync_strings.py` gelaufen).
6. Wer etwas entfernt, entfernt es vollständig: Code, Bridge-Befehl, Oberflächen beider Plattformen, Tests, Doku.

---

## 5. Sicherheits- und Verhaltensregeln (verbindlich)

- **Die echte Anlage nicht verstellen.** Zum Prüfen nur lesen (Zustand, Diagnose, Suche). Kein Ein/Aus, kein Modus,
  keine Temperatur, keine Timer, keine Szenen, kein „Leistung begrenzen“ ohne ausdrücklichen Auftrag.
- **Keine Cloud-Anmeldung auslösen** und keine Passwörter eingeben, speichern oder ausgeben. Jede Anmeldung kann die
  Sitzung eines anderen Geräts entwerten („Konto anderswo eingeloggt“); zu viele Anmeldungen können das Konto sperren.
- **Geheimnisse** (Token, Schlüssel, Passwort, Cloud-Sitzung, Zugangsdaten-Sicherungen) nie loggen, nie in Dateien
  im Repo, nie in Ausgaben oder Berichte. Protokollausgaben laufen über `AppLog`, das schwärzt; neue Felder mit
  Geheimnissen müssen in die Schwärz-Regeln.
- **Nichts hart löschen.** Mac: Papierkorb (`FoundationPlatform.discard`); Windows: umbenennen mit Zeitstempel
  (`…entfernt-<Unix>.json`). Gilt auch für Agenten bei Aufräumarbeiten.
- **Keine persönlichen Daten ins Repo:** keine echten Geräte-IDs, Seriennummern, MAC-/IP-Adressen, Raum- oder
  Kontonamen, E-Mails, Rechnernamen, Benutzerpfade. Testdaten sind erfunden und bleiben es:
  `net_ac_1A2B`, `192.168.1.40`, Geräte-IDs `111122223333444`/`111122223333555`, LAN-ID `20015998343868`,
  E-Mails `…@example.com`. Screenshots vor dem Einchecken auf Namen, Adressen und Konten prüfen.
- **Tests fassen nichts Echtes an** (Details 11.2). Kein Netz außer `127.0.0.1`.
- Die öffentlich bekannten Konstanten der Midea-Cloud (App-ID, App-Key, Discovery-Schlüssel) stammen aus
  msmart-ng und sind keine Geheimnisse; sie bleiben im Code.

---

## 6. Protokoll und Anlage

### 6.1 Discovery (Suche im WLAN)

- UDP an Port **6445 und 20086**, je 3× als Broadcast an `255.255.255.255` (oder gezielt an eine IP), Wartezeit
  standardmäßig 4 s. Die Antwort ist mit AES-ECB und einem **festen, öffentlich bekannten** Schlüssel verschlüsselt
  und enthält IP, Port 6444, Geräte-ID, Seriennummer, Name `net_ac_XXXX`, Typ 0xAC, Protokoll V2/V3.
- Zusätzlich gibt es eine Unicast-Suche über das ganze /24 (`SetupFlow.scanSubnet`) für Netze, die Broadcast filtern.
- `Discovery.find(deviceId:)` sucht gezielt die gespeicherte Anlage („Adresse neu suchen“).
- **Discovery-Antworten sind fälschbar.** Neue Adressen erst nach gelungenem Handshake mit dem gespeicherten Token
  übernehmen – nie ungeprüft.
- Leere Ergebnisse am Mac bedeuten oft, dass die Freigabe „Lokales Netzwerk“ verweigert ist (kein Fehler, nur leer).

### 6.2 LAN-Transport V3 (8370)

- TCP 6444. Handshake (Typ 0x0) mit dem 64-Byte-Token, Antwort (0x1) liefert den Sitzungsschlüssel (32 Byte
  verschlüsselt + 32 Byte SHA256). Danach AES-128-**CBC mit Null-IV** und SHA256 über den Klartext (kein HMAC).
  Paket-Typen: 0x3 verschlüsselte Antwort, 0x6 verschlüsselte Anfrage, 0xF Fehler.
- Im 8370-Paket steckt ein V2-Paket (0x5A5A) mit Zeitstempel und Geräte-ID; darin der mit AES-ECB (fester Schlüssel)
  verschlüsselte Befehlsrahmen, MD5-signiert. Diese Krypto-Grenzen gibt Midea vor; sie sind nicht verbesserbar.
- Größtes angenommenes 8370-Paket ist begrenzt (echte Antworten < 300 Byte); ein unsinniges Längenfeld wird
  übersprungen und neu synchronisiert.
- Unter Windows/Linux baut `AESModes` ECB/CBC aus einzelnen AES-Blöcken (swift-crypto kennt kein ECB) und hängt an
  der Unterstrich-API `_CryptoExtras`. Bei jedem swift-crypto-Update müssen die `AESModes`-Tests gegen CommonCrypto
  (macOS) grün sein, bevor eine Windows-Ausgabe gebaut wird.

### 6.3 Zeiten und Grenzen – nicht ändern ohne Live-Messung

| Wert | Größe | Warum |
|---|---|---|
| Pause nach dem Handshake | 0,5 s | sonst verwirft die Anlage den ersten Befehl |
| Pause zwischen Wiederholungen | 1,5 s | die Anlage braucht Zeit zwischen Versuchen |
| `idleDisconnect` | 8 s | Verbindung danach trennen, damit andere Apps (Midea-App, zweiter Rechner) zum Zug kommen |
| `commandBudget` | WLAN ~10 s, Cloud 12 s (min. 2 s) | danach Abbruch mit klarer Meldung statt bis zu 30 s Warten |
| `freshStateAge` | 3 s | so jung darf ein Zustand sein, damit ein Befehl ihn statt einer neuen Abfrage nutzt |
| Zusatzmeldungen abwarten | 0,1 s | nur, wenn die erwartete Antwort im ersten Rahmen fehlt (spart ~1 s je voller Abfrage) |

- Die Anlage nimmt **nur eine LAN-Verbindung gleichzeitig** an. „Belegt“ ist kein Codefehler, sondern eine andere
  Verbindung (Midea-App, zweites Klimacontrol, eigene Diagnose mit Takt < 8 s).
- Nach Ablauf des Zeitbudgets ist offen, ob der Befehl ankam – so melden, **nicht stillschweigend wiederholen**.
  Ging ein Stellbefehl im WLAN schon hinaus (`failedAfterWrite`), weicht „Automatisch“ dafür nicht auf die Cloud aus;
  eine Wiederholung im WLAN nach dem Senden wartet die 1,5 s wie zwischen Stellversuchen.
- Zwei Schaltbefehle direkt hintereinander (< 1 s) übernimmt die Anlage nicht zuverlässig; darum hält der Kern
  zwischen zwei Zonen-Wechseln am Lüfter 2 s Abstand (`zoneGap`, verschoben statt verschluckt), schickt
  Lüfterbefehl und „Außengerät leise“ nacheinander und entprellt Regler (`debounced`).

### 6.4 Befehlsrahmen

Rahmen beginnen mit `0xAA`, Länge, Gerätetyp `0xAC`, …, Nachrichtentyp (`0x02` Steuern, `0x03` Abfrage, `0x04`
Meldung), Nutzdaten, Prüfsumme; die Nutzdaten tragen eine CRC8. Wichtige Nutzdaten (nach msmart-ng
`device/AC/command.py`):

| Befehl | Kennung | Bemerkung |
|---|---|---|
| Zustand abfragen | `0x41 0x81 …` | Antwort `0xC0` = Grundzustand |
| Fähigkeiten | `0xB5 0x01 0x00` | 2 Seiten, ausgewertet wie msmart-ng |
| Gruppen-Daten (Diagnose) | `0x41 0x21 0x01 0x40\|Gruppe` | Gruppen 0–7, 12 |
| Anzeige am Gerät umschalten | `0x41 0x02\|Ton …` | nur Umschalten, kein fester Zustand |
| Eigenschaften lesen | `0xB1 n id…` | Antwort `0xB1` |
| Eigenschaft setzen | `0xB0 1 id len wert` | Antwort `0xB0` |
| Zustand setzen | `0x40 …` | Ein/Aus, Modus, Soll, Lüfter, Schwenken, Eco, Turbo, Ionisierer, Frostschutz |

Eigenschaften (`PropertyId`): `0x0039` Selbstreinigung, `0x0048` Leistung begrenzen, `0x00CD` Außengerät leise
(Wert 3 = an), `0x00E3` iECO, `0x022C` Signalton. Modi: 1 Auto, 2 Kühlen, 3 Trocknen, 4 Heizen, 5 Lüften.
Lüfter: 1–100 % stufenlos, Stufen 20 Leise · 40 Niedrig · 60 Mittel · 80 Hoch · 100 Max · 102 Auto. Schwenken nur
vertikal (`0x0C`). Temperatur nur **ganze Grad** 16–30 °C (bewusste Entscheidung; die Fähigkeiten melden keine
Nachkommastellen).

### 6.5 Stellbefehle

Jeder Stellbefehl wird **verifiziert** (zurückgemeldeter Zustand verglichen) und bis zu 3× wiederholt. Bei
endgültigem Fehlschlag springt die Oberfläche auf die Ausgangswerte zurück und es folgt ein frischer Abruf.
Maßgeblich ist immer, was die Anlage zurückmeldet (z. B. „Leistung begrenzen 75 %“ wurde gesendet, aber nicht
übernommen → als Fehler melden). Ein am Gerät gestellter Gerätetimer bleibt bei Befehlen erhalten.

### 6.6 Messwerte und ihre Eigenheiten

- **Energiezähler** (Gruppe 4, Byte 4–7) ist **binär**, 1 Schritt = 0,01 kWh – nicht BCD (msmart-ng liest BCD; bei
  der PortaSplit falsch). Belegt durch 77 h Verlauf: 10,0 Wh je Schritt gegen Leistung × Zeit. Rücksprünge ≤ 2
  Schritte sind Rundung; Zuwächse über `maxPlausibleKW` (2,5 kW) × Zeit sind Lesefehler und werden verworfen.
  Rohwert 0 = unbekannt; `0xFFFFFFFF` kommt beim Einschalten vor.
- **Leistung** (Gruppe 4, Byte 16–18) ebenfalls binär / 10 W.
- **Außentemperatur bei ausgeschalteter Anlage** meldet die PortaSplit immer exakt 10,0 °C → als „unbekannt“
  behandeln (andere Anlagen liefern echte Werte).
- Herkunft aller Werte: Anhang C.

### 6.7 Cloud

- Zwei Zugänge: **MSmartHome/meiju** (`SmartHomeClient`, bevorzugt) und **NetHome Plus** (`NetHomePlusClient`,
  Rückfall). Anfragen über `/mas/v5/app/proxy?alias=…` bzw. direkt; Endpunkte u. a. `/v1/user/login/id/get`,
  `/v1/user/login`, `/v1/iot/secure/getToken`, `/v1/appliance/user/list/get`, `/v1/appliance/transparent/send`.
- **Token-Abruf:** `udpid` = SHA256 der Geräte-ID, Hälften XOR; bei der PortaSplit in **big endian** bestätigt,
  little endian bleibt Rückfall. Token und Schlüssel werden per Handshake an der Anlage geprüft, bevor sie
  gespeichert werden. Mideas Abruf ganz ohne Anmeldung antwortet derzeit mit Fehler 9999.
- **Sitzung:** `MideaCloudSession` ist ein `actor`, wird je Rechner gespeichert und wiederverwendet (Mac:
  Schlüsselbund, Windows: Anmeldeinformationsverwaltung). Rückzug nach Fehlern 60 s, verdoppelnd bis 30 min. Bei
  falschem Passwort Stopp bis zur Nutzeraktion – nie automatisch wiederholen. Netzfehler (kein Internet, HTTP 5xx,
  Zeitbudget) behalten die Sitzung; gleichzeitige Vorgänge teilen sich eine laufende Anmeldung.
- Die Geräte-ID gegenüber Midea (`MideaCloudDeviceId`) ist dauerhaft gespeichert; eine je Start neue ID ließ Midea
  jedes Mal ein neues Gerät sehen („Konto anderswo eingeloggt“).
- Nur die Anlage mit passender Geräte-ID steuern; Cloud-Suchergebnisse werden 2 min zwischengespeichert, damit ein
  zweiter Klick keine neue Anmeldung auslöst.
- Fehler **3123** = „Anlage offline“ (aus oder stromlos): ruhiger Hinweis statt Fehler, Cloud 5 min nicht fragen.

### 6.8 Wegwahl (`AutoTransport`)

`ConnectionMode`: **Automatisch** (Standard: WLAN zuerst, dann Cloud), **Nur WLAN**, **Nur Cloud (unterwegs)**.

- Nach einem WLAN-Fehler wird WLAN `retryInterval` = 60 s übersprungen; antwortet derweil die Cloud, verdoppelt sich
  die Sperre bis `maxRetryInterval` = 300 s.
- Scheitern alle Wege aus einem anderen Grund als 3123, fallen alle Sperren – die nächste Abfrage beginnt mit WLAN.
- Cloud-Fehler 3123 sperrt die Cloud `cloudOfflineInterval` = 300 s.
- „Jetzt aktualisieren“ (⌘R), das Sichtbarwerden eines Fensters und `resetBackoff()` heben alle Sperren auf.
- Unbekannte gespeicherte Wege werden beim Start zu „Automatisch“. Bluetooth bietet die Anlage nicht als
  Steuerkanal; `bleSerial` in `device.json` wird nur mitgeführt.

---

## 7. Kern (`KlimacontrolCore`)

### 7.1 `ACController`

`@MainActor`, `@Observable`. Erzeugt mit `ACController(appVersion:dependencies: CoreDependencies(…), autostart:)`;
der Initialisierer mit Einzelparametern (`ACController(appVersion:settings:paths:…)`) bleibt. Tests übergeben
`MemorySettings`, `CorePaths(directory:)`, eine Fake-Plattform, eine nachgebildete Anlage (`ACDevice`), einen
`CloudAccountStore` im Speicher und bei Bedarf eine Uhr (`now`). Prüf-Haken: `c.probe` bzw.
`c.setup.probe = CredentialProbe { … }`, Suche über `c.locate`.

- `message` ist von außen nur lesbar; Oberflächen räumen sie mit `clearConnectionError()` weg.
- Ergebnisse sind typisiert: `CommandOutcome` (übernommen · nicht übernommen mit echtem Stand · unklar · gescheitert
  · verworfen), `CredentialCheck`; keine Vergleiche von Fehlertexten.
- `debounced` nimmt `DebounceKey` (`.temperature`, `.fan`), Verzögerung `debounceDelay` (700 ms).
- `stop()` beendet Abfrage, Timer-Schleife, `timerFireTask`, gesammelte Befehle und Verbindung. Die Schleifen halten
  den Controller während ihrer Pausen nicht fest.

Wichtige Eigenschaften: `state` (letzter `ACState`), `diagnostics`, `connectionState`, `busy`, `staleSince`,
`message` (Fehlerzeile), Notiz (`showNotice`/`clearNotice`), `displayName`, `refreshSeconds`, `pricePerKWh`,
`connectionMode`, `beep`, `historyCSV`, `cloudConfigured`, `appearance`, `setup` (`SetupFlow`).

Wichtige Aktionen: `refresh()`/`refreshNow()`, `setPower`, `setMode`, `setTemperature`, `nudgeTemperature(by:)`,
`setFan(_:now:)`, `setFanQuiet`, `setFanTurbo`, `setEco`, `setTurbo`, `setOutdoorSilent`, `setSelfClean`, `setIECO`,
`toggleDisplay`, `setRate`, `setSound`, `update { … }` (beliebige Zustandsänderung), `debounced(_:_:)`,
Timer (7.3), Szenen (`apply`, `saveCurrentAsScene`, `deleteScene`, `isActive`), `cloudLogin`/`cloudLogout`,
`importBackupChecked`, `exportBackup`, `forgetDevice` (Neu einrichten), `relocate()` (Adresse neu suchen),
`setAppearance`, `applyTheme`, `resetAppearance`, `stop()`.

### 7.2 Abfrage-Takt

- `refreshSeconds` 1–600 s (Einstellung). Oberflächen melden Sichtbarkeit mit `setUIVisible(id, visible)` (IDs z. B.
  `main`, `menu`). Ist keine sichtbar, fragt der Kern höchstens alle `backgroundRefreshSeconds` = 30 s.
- Unter 8 s bleibt die Verbindung offen (andere Apps kommen dann nicht an die Anlage); unter 5 s **Schnellmodus**:
  je Sekunde Zustand plus ein Diagnose-Block im Wechsel (`fastCycle` = Gruppen 0, 1, 2, 3, 5, 7).
- Diagnose wird nur gelesen, wenn die Diagnose-Spalte offen ist (`showDiagnosticsPanel`).
- Der periodische Abruf liest immer frisch, sodass Steuerung durch andere Apps sichtbar wird.
- **Automatische Adresssuche:** nach 3 WLAN-Fehlern in Folge (`relocateAfterFailures`), höchstens alle 10 min.

### 7.3 Timer

- „Ausschalten in …“ (`setOffTimer(in:)`) und „Einschalten um …“ (`setOnTimer(hour:minute:)`); gespeichert in
  `timerOffAt`/`timerOnAt`. Der Einschalt-Timer speichert nur Stunde/Minute; der Tag wird immer frisch aus „jetzt“
  bestimmt.
- Die App schaltet selbst (die PortaSplit nimmt Gerätetimer per LAN nicht an). Solange ein Timer läuft, verhindert
  `PlatformServices.keepAwake` den Ruhezustand (Bildschirm darf aus).
- Kulanz 5 min (`timerGrace`): War der Rechner länger aus, gilt der Timer als verpasst – das ist etwas anderes als
  „Anlage nicht erreichbar“ und wird anders gemeldet. Wiederholung alle 10 s, Schlaf der Schleife höchstens 300 s.
- Ergebnisse gehen über `onTimerResult` an die Oberfläche (Mitteilung).

### 7.4 Energie und Kosten

- Tagesbeginn wird gespeichert als `JJJJ-MM-TT;kWh;Geräte-ID;Unix-Sekunden;1|0` (`energyDayStart`); nur Einträge der
  binären Lesart gelten. Der alte Schlüssel `dayStart-JJJJ-MM-TT` wird noch gelesen – Lesepfad ab 2027-01-01 entfernen.
- `todayEnergy` liefert kWh, ab wann gezählt wird („seit 08:14“, wenn nicht ab Mitternacht) und eine
  Plausibilität (±50 % gegen die Summe der gemessenen Leistung).
- `costPerHour` = aktuelle Leistung × Strompreis.

### 7.5 Einrichtung (`SetupFlow`)

Drei Wege (`SetupPath`): **Midea-Konto** (empfohlen), **Zugangsdaten** (ohne Konto), **Sicherung**. Danach nur der
Ablauf des gewählten Wegs. Die Prüfung der Zugangsdaten unterscheidet „abgelehnt“, „belegt“ und „antwortet nicht“;
nur echte Ablehnung ist ein Fehlschlag. Späte Rückrufe alter Subnetz-Suchen werden verworfen. Beim Weg
„Zugangsdaten“ gibt es keinen Cloud-Weg → „Nur WLAN“ und „Zugangsdaten sichern“ werden vorgeschlagen
(`applySuggestedMode`). Eine über die Cloud gefundene Anlage (ohne WLAN-Token) bekommt den WLAN-Weg automatisch,
sobald sie im selben Netz antwortet.

### 7.6 Verlauf

- `verlauf.sqlite`: Tabelle `verlauf (zeit INTEGER PRIMARY KEY, …Spalten wie CSV…)`, Tabelle `meta (name, wert)`.
  Alle 10 s ein Punkt (Zustand + Diagnose).
- **Ausdünnen in Stufen:** älter als 24 h → 1 Punkt je Minute, älter als 30 Tage → je 15 min, älter als 365 Tage →
  je Stunde. Läuft im Hintergrund (`klimacontrol.history.compact`) in Scheiben à 6 h.
- Lücken: Für die Statistik (Mittel, Verbrauch aus Leistung × Zeit) zählt ein Abstand zwischen zwei Punkten nur bis
  10 min (dichte Daten), 25 min (je Minute) bzw. 70 min (ältere Stufen) mit (`HistoryDB.gapLimits`). Die Graphen
  trennen die Linie dagegen ab `UIOptions.chartGapThreshold(range:)` = max(180 s, 3 × Zeitfenster), bei ~600 Fenstern
  je Zeitraum.
- `gesamt_kwh` ist erst ab dem Merker „Zähler binär ab“ richtig; davor gilt nur `zaehler_roh` × 0,01 kWh. Ältere
  Fassungen schrieben im Aus-Zustand 10,0 °C außen als Platzhalter (wird beim Mitteln ausgefiltert).
- Optional zusätzlich `verlauf.csv` alle 30 s (`historyCSV`, Standard aus).
- Export: technische Form (ISO 8601 mit Zone, Spaltennamen wie Anhang B, immer deutsch) oder lesbare Form (Spaltennamen
  mit Einheit, Modus-Namen und Dezimalzeichen nach Sprache der Oberfläche bzw. Format, Ortszeit). Beide lassen sich
  wieder einlesen; der Import erkennt die deutsche und die englische lesbare Form sowie beide Dezimalzeichen. Die
  Datenbank und `verlauf.csv` bleiben deutsch.
- Spalten stehen nur in `HistoryColumn`; neue Spalten nur hinten anhängen (die Tabelle bekommt sie per ALTER TABLE,
  `verlauf.csv` wird bei neuer Kopfzeile beiseitegelegt), Anhang B und die wörtliche Kopfzeile in `HistoryTests`
  bewusst mitändern.
- **Verbrauch je Tag/Woche/Monat** (`energyPeriods`): Zähler am Ende − Zähler am Anfang. Als Stand an einer Grenze gilt
  die letzte Zeile höchstens 15 min davor (wie beim Tagesbeginn, `counterAtDayStart`); sonst die nächste Zeile im
  Zeitraum, und der Zeitraum gilt als unvollständig. Rücksprung über die Rundung oder mehr als `maxPlausibleKW` × Zeit →
  kein Zählerwert, dann Leistung × Zeit („ca.“). Grenzen in Ortszeit über einen Kalender (Woche ab Montag), nie mit
  festen 86 400 s.
- Lesbare Zeiten ohne Zone: Bei der doppelten Stunde am Ende der Sommerzeit gilt das früheste Vorkommen, das nicht vor
  der vorigen Zeile liegt (`resolveRepeatedHour`) – welches Vorkommen Foundation liefert, unterscheidet sich je Plattform.

### 7.7 Einstellungen (`SettingsKey`)

`displayName`, `refreshSeconds`, `pricePerKWh` (0–1000), `currency`, `language` (Windows; Mac: Systemsprache), `updateBetaChannel` (Mac), `connectionMode`, `beep`, `timerOffAt`, `timerOnAt`,
`energyDayStart`, `showDiagnosticsPanel`, `historyCSV`, `credentialsBackedUp`, `appearance` (JSON),
`loginItemDefaultOn` (Mac: „Beim Anmelden starten“ schon einmal eingetragen), `lastOpenedColumn` und `columnsBeforeFullScreen` (Mac: zuletzt geöffnete Seitenspalte; Spalten vor dem Vollbild). Mac: in
`UserDefaults` (Domäne `de.mlafx.klimacontrol`), Windows: über die Bridge im Kern gespeichert (`UserDefaults.standard` von swift-corelibs-foundation, Datei `%LOCALAPPDATA%\Klimacontrol.exe.plist` – der Name folgt dem Prozessnamen; seit 1.0 so, darum nicht verlegen, das Setup legt den Namen der exe fest). Neue Schlüssel immer
in `SettingsKey` anlegen, nie als String-Literal in einer Oberfläche.

### 7.8 Darstellung (`Appearance`)

| Feld | Werte | Standard |
|---|---|---|
| `theme` | standard, night, neon, minimal, contrast | standard |
| `scheme` | system, light, dark | system |
| `accent` | byMode, system, custom | byMode |
| `customColor` | orange, blue, green, purple, gray | orange |
| `background` | glass, glassStrong, matte | glass |
| `transparency` | 0 … 0,95 | 0,4 |
| `blur` | 0 … 40 pt | 20 |
| `glow` | 0 … 1 | 0 |
| `size` | compact, normal, large | normal |
| `digits` | thin, normal, bold, rounded | normal |
| `hero` | target (Soll), room (Raum) | target |
| `scope` | simple („Einfach“), all („Alles“) | all |
| `lively`, `weather`, `reduceMotion`, `alwaysOnTop` | an/aus | aus |
| `menuBarText` | iconOnly, iconTarget, iconRoom, roomTarget | iconTarget |
| `menuBarColored` | an/aus | Mac aus, Windows an (`platformColoredIcon`) |
| `menuBarAnimated` | an/aus | aus |

- `Appearance.standard` muss **exakt** dem Aussehen vor Einführung des Reiters „Darstellung“ entsprechen.
- Ein Thema (`preset`/`applying`) setzt nur Aussehens-Werte; Größe, „Groß angezeigt“, Umfang, „Animationen
  reduzieren“, Vordergrund, Menüleisten-Text und animiertes Symbol bleiben erhalten.
- `Appearance.isCustomized` (`ACController.appearanceIsCustomized`, Schnappschuss-Feld `appearanceCustomized`): ein Aussehens-Wert
  weicht von `applying(theme)` ab (Regler mit Toleranz); Größe, Groß angezeigt, Umfang, Animationen reduzieren, Vordergrund,
  Menüleisten-Text und animiertes Symbol zählen nicht. Die Themenkachel trägt dann „angepasst“, „Thema wiederherstellen“
  ruft `applyTheme` für das gewählte Thema auf.
- Decoding ist robust: fehlende, unbekannte oder falsch getippte Felder → Standard, Zahlen werden geklemmt, nie ein
  Fehler (eine kaputte Einstellung darf den Start nie verhindern). Tests in `AppearanceTests`.
- Bewegte Effekte nur, wenn `motionAllowed` (weder „Animationen reduzieren“ noch System-„Bewegung reduzieren“), nur
  bei sichtbarem Fenster und nur, solange die Anlage arbeitet; höchstens 30 fps.

### 7.9 Meldungen

Texte für Fehler und Hinweise kommen aus `UserMessage`/`Fmt` im Kern und aus dem Katalog (Schlüssel `message.*`,
`reason.*`): „Was ist passiert. Was tun. (code)“ – der Code klein am Ende in Klammern, z. B. `(path-missing)`.
Oberflächen erfinden keine eigenen Fehlertexte. Die Rohtexte in MideaKit (`errorDescription`, `what`/`todo`, Hinweise)
gehen nur ins Protokoll bzw. in `UserMessage.detail`; sichtbar werden sie nie als Haupttext. Ursachen von Verbindungsfehlern sind Typen (`ConnectionReason`, `BusyCause`, `PathFailure.Reason`); der Kern bildet sie auf Katalogtexte ab (`DisplayNames.swift`), nie über Textvergleich.

**Protokollzeilen stehen in der Sprache der Oberfläche** (Stufe `FEHLER`/`ERROR` und `WARNUNG`/`WARNING` eingeschlossen);
bereits geschriebene Zeilen bleiben, wie sie sind. Im Kern, in der Bridge und in der Mac-App stehen die Zeilen im
Katalog (`log.<bereich>.<name>`, typisiert `L.Log.…`). MideaKit kennt den Katalog nicht und ruft
`LogText.t("log.<bereich>.<name>", "deutscher Text mit {platzhalter}", ["platzhalter": wert])` auf; Fehlertexte aus
MideaKit heißen `kit.<typ>.<name>` (bereits vorhandene Texte nutzen ihren Schlüssel `reason.*` mit). Der Kern installiert
den Übersetzer (`Localizer.configure`, `ACController.init`); ohne ihn gilt der deutsche Text im Code.
`LogTextTests` vergleicht jeden Schlüssel und den deutschen Text im Code mit dem Katalog, damit beide nicht
auseinanderlaufen. Bleibt deutsch: Datenbank, technische CSV-Form, `ConnectionPath.rawValue`, `label` der Modi
(Datenbank/CSV). Fehlertypen und Bedingungen werten nie einen Protokoll- oder Fehlertext aus (12).

Alle übrigen Anzeigetexte, Auswahllisten, Grenzen, Gültigkeitsregeln und Rückfragen stehen im **Anzeige-Katalog**
(`UIOptions`, `UIText`, `ACController+DisplayText`); Oberflächen halten keine eigenen Texte oder Regeln. Neue Texte
zuerst dort anlegen und in `DisplayCatalogTests` wörtlich festschreiben, dann über die Bridge an Windows geben.

---

## 8. Bridge (C-Schnittstelle für Windows)

### 8.1 Regeln für den Aufrufer

- Alle `kc_*`-Funktionen auf dem **Hauptthread** aufrufen (WPF-UI-Thread = Hauptthread des Prozesses).
- `kc_set_locale` vor `kc_init` aufrufen (Windows: in `Core.Init` vor `Native.Init`).
- `kc_pump()` regelmäßig (~alle 30 ms) aufrufen: leert die Main-Queue, auf der der MainActor läuft.
- Zurückgegebene Zeichenketten (UTF-8) mit `kc_free` freigeben.
- Beim Start `kc_api_version()` mit der eigenen Erwartung (`Native.ExpectedApi`) vergleichen; passt sie nicht,
  stammen exe und DLL aus verschiedenen Ständen → klare Fehlermeldung.

### 8.2 Funktionen

| Funktion | Zweck |
|---|---|
| `kc_api_version()` | Version der Schnittstelle (heute **3**) |
| `kc_init(version)` | Kern starten (mehrfach harmlos) |
| `kc_pump()` | Main-Queue einmal leeren |
| `kc_stop()` | Abfrage, Timer, Verbindung beenden |
| `kc_state_rev()` | Revisionszähler; steigt, wenn sich eine im Schnappschuss gelesene Eigenschaft ändert |
| `kc_state_json()` | voller Schnappschuss (nur abrufen, wenn `kc_state_rev` gestiegen ist) |
| `kc_live_json()` | kleiner, häufig gelesener Teil (`busy`, `nextRefresh` …) |
| `kc_command(json)` | Befehl ausführen; Antwort JSON mit Erfolg oder fertigem Fehlertext |
| `kc_history_json(…)`, `kc_history_stats_json(…)` | Verlauf und Statistik für die Graphen |
| `kc_set_locale(json)` | vor `kc_init`: Sprache und Formate; nil = übernommen, sonst Meldung, mit `kc_free` freigeben |
| `kc_strings_json()` | Texte der aktiven Sprache, `{language, pseudo, strings}` |
| `kc_energy_json(kind, count)` | Verbrauch je Zeitraum (`day`/`week`/`month`, 1–60): `{kind, periods, summary}` bzw. `{error}`; Zeiten in Unix-Sekunden |
| `kc_log_tail()` | Ende des Protokolls (Reiter „Protokoll“) |
| `kc_third_party_json()` | Lizenzhinweise |
| `kc_support_dir()` | Ablageordner |
| `kc_free(p)` | Zeichenkette freigeben |

### 8.3 Befehle (`{"cmd": "...", …}`)

Fehlt ein Pflichtparameter oder hat er den falschen Typ, antwortet `kc_command` mit Fehler – **nie** mit einem
stillen Standardwert. Booleans und Zahlen werden streng unterschieden (`1` ist kein „an“, `true` keine Zahl).
Passwörter in Befehlen werden nie protokolliert. Neue Befehle in `BridgeCommands.swift` **und** in `Cmd`
(`windows/KlimacontrolTray/BridgeCommands.cs`) eintragen; `BridgeCommandTests` (Swift) und `VertragTests` (C#)
gleichen beide ab.

| Gruppe | Befehle (Parameter) |
|---|---|
| Bedienung | `refresh`, `power(on)`, `mode(value)`, `temp(value)`, `nudgeTemp(delta)`, `fan(value, now?)`, `fanQuiet(now?)`, `fanTurbo(now?)` |
| Schalter | `swing(on)`, `eco(on)`, `turbo(on)`, `purifier(on)`, `freezeProtection(on)`, `outdoorSilent(on)`, `selfClean(on)`, `ieco(on)`, `display`, `rate(value)`, `sound(on)` |
| Szenen | `applyScene(id)`, `deleteScene(id)`, `saveScene(name)` |
| Timer | `offTimer(minutes?)`, `onTimer(hour, minute)` bzw. `onTimer(at?)` |
| Einstellungen | `connectionMode(value)`, `displayName(value)`, `refreshSeconds(value)`, `price(value)`, `language(value)`, `currency(value)`, `debugLog(on)`, `historyCSV(on)`, `diagnosticsVisible(on)`, `uiVisible(id, visible)` |
| Darstellung | `appearance(value: Objekt)`, `appearanceTheme(theme)`, `appearanceReset` |
| Daten | `exportHistory(path, from?, until?, readable?)`, `exportHistoryStart(path, from?, until?, readable?)` (im Hintergrund, `readable` Standard an; Ergebnis `exportSeq`/`exportError`), `clearLog`, `importBackup(path, replaceScenes?, allowOtherDevice?)`, `exportBackup(path)` |
| Konto | `cloudLogin(account, password)`, `cloudLogout` |
| Einrichtung | `setupPath(value?)`, `scan(ip?)`, `scanSubnet`, `scanCloud(account, password)`, `select(id?)`, `setupConnect(account, password)`, `manualSet(ip?, port?, deviceId?, token?, key?)`, `manualUse(id)`, `manualPaste(text)`, `manualCheck`, `manualConnect`, `applySuggestedMode`, `dismissCompletion` |
| Anlage | `forgetDevice`, `relocate` |
| Meldungen | `dismissMessage`, `dismissNotice`, `dismissWhatsNew` |

Bedienregeln (Modus, Eco, Turbo, Ein/Aus, Lüfter-Zonen) setzt die Bridge über die Kern-Funktionen (`setMode`,
`setEco`, …), nie über `update { … }` mit eigenen Regeln. Fertige Anzeigetexte kommen ebenfalls aus dem Kern
(`miniValue`, `miniCaption`, `working`, `relocateMessage`, `heroValue`, `heroCaption`, `costLine`, `menuTitle`,
`staleText`, `noticeDetail` …). Der Schnappschuss trägt außerdem `appearanceCustomized`, `options` (Listen, Grenzen, feste Rückfragen) und
`availability` (je Schalter `enabled`/`why`); Rückfragen zu Befehlen kommen über `importResult.text`/`prompt`,
`setup.completion.prompt`, `quitPrompt`, `whatsNew` (nach einem Update; bestätigen mit Befehl `dismissWhatsNew`) und `options.prompts.forget`/`forgetNeedsBackup` (Auswahl über `forgetNeedsBackup`);
`options.prompts.cloudNeedsAccount` erklärt, warum „Nur Cloud“ ohne Midea-Konto nicht geht. `options.energy` trägt Arten,
Überschrift, Hilfe und Legende des Verbrauchs. Zeitabhängige Texte (`connectionLine`, `offTimerChip`,
`nextRefreshLine`) stehen nur in `kc_live_json`, weil der Schnappschuss nur bei Änderungen neu gelesen wird.

Ergebnisse langlaufender Befehle (Anmeldung, Einrichtung, Adresse neu suchen, Sicherung einlesen, Export) stehen im
Schnappschuss mit eigenem Zähler (`loginSeq`, `setupSeq`, `relocateSeq`, `importSeq`) und Ergebnisfeld.

### 8.4 Vertrag ändern

- Nur **additiv** erweitern. Wer Felder, Befehle oder Bedeutungen ändert, erhöht `bridgeAPIVersion` **und**
  `Native.ExpectedApi` gemeinsam und passt `windows/KlimacontrolTray.Tests/Vertrag/bridge-muster.json` an
  (`VertragTests` prüft, dass die Oberfläche das Muster lesen kann).
- JSON wird mit **fester Schlüsselreihenfolge** (`sortedKeys`) kodiert; Foundation unter Windows ordnet sonst je
  Aufruf anders und die Oberfläche zeichnete ständig neu.
- Scheitert das Kodieren, liefert die Bridge den letzten guten Schnappschuss und protokolliert den Fehler einmal.
- Der Bridge-Code wird auch am Mac übersetzt (nicht gelinkt), damit Umbenennungen im Kern sofort auffallen.

---

## 9. Mac-App

### 9.1 Fenster und Szenen

Der Reiter „Darstellung“ ist von oben: Vorschau · Thema (fünf Kacheln mit Mini-Vorschau, Hell/Dunkel/System, bei Abweichung
„Thema wiederherstellen“) · Anzeige (Größe, Groß angezeigt, Umfang) · Fenster und Menüleiste · „Anpassen“ (zugeklappt;
Farbe, Hintergrund, Transparenz, Unschärfe, Leuchten, Ziffern, Bewegung) · Auf Standard zurücksetzen.

Hauptfenster (Kopf, große Zahl, Bedienung; links Verlauf ⌘G, rechts Diagnose ⌘D, unten Fußzeile mit Verlauf ·
Aktualisieren/Einstellungen · Diagnose), Menüleiste (`MenuBarExtra` mit Schnellsteuerung), Mini-Fenster
(`id: "mini"`, ⇧⌘M, schwebend), Einstellungen (⌘,) mit Reitern **Allgemein · Darstellung · Verbindung · Anlage ·
Protokoll · Lizenzen** (Fensterhöhe 600). Rückmeldungen der Einstellungen stehen am Ort der Aktion, nicht im Banner
des Hauptfensters. Oben im Reiter Allgemein steht die Sprachwahl (Systemsprache · Deutsch · English) mit dem Knopf
„Jetzt neu starten“; die Wahl wirkt erst nach dem Neustart (Details 9.4, 13.2).

**Größe und Vollbild des Hauptfensters.** Das Fenster ist in der Größe veränderbar (`contentMinSize`) und kann ins
Vollbild. Nichts wird skaliert: Die Steuerspalte bleibt 480 pt breit, zusätzlicher Platz gehört dem Verlauf, dann der
Diagnose (Verteilung und Grenzen in `MainWindowLayout`: Verlauf ab 460, ab 880 Graphen als 2 × 2; Diagnose 340–400;
nur Steuerung höchstens 520). Die Mindesthöhe hängt von der Darstellungsgröße ab (470/520/600), die Höhe gehört dem
Nutzer. Beim Einblenden einer Seitenspalte wächst das freie Fenster nur um den Fehlbetrag (Verlauf nach links,
Diagnose nach rechts, Steuerung bleibt am Platz), beim Ausblenden nimmt es nur das selbst Angebaute zurück (`WindowRef`,
sonst nichts: maximiert, gekachelt und Vollbild werden nicht verändert). Passen die Mindestbreiten nicht auf den
Bildschirm, bleibt nur die zuletzt geöffnete Spalte (mit Ansage). Im Vollbild sind Verlauf und Diagnose eingeblendet
(vorher gespeicherter Zustand kehrt beim Verlassen zurück), „Immer im Vordergrund“ ist dort ausgesetzt, der
Fensterhintergrund ist deckend. `ControlStack` bleibt unverändert (auch im Menüleisten-Fenster).
Die Diagnose-Spalte erscheint nur mit einem Zustand der Anlage (`hasState`); ohne Verbindung (z. B. Test ohne Anlage) fehlt
sie, das ist kein Fehler. Während des Ziehens an der Fenstergröße bleibt die Fläche der Graphen eingefroren (9.3).

### 9.2 Tastenkürzel

Zentral in `AppCommands`, nur aktiv, wenn Haupt- oder Menüleisten-Fenster Key ist (sonst würden Eingaben in
Textfeldern der Einstellungen Befehle auslösen):

| Kürzel | Wirkung | Menü |
|---|---|---|
| ⌘P | Ein/Aus | Anlage |
| ⌘↑ / ⌘↓ | wärmer / kälter | Anlage |
| ⌘R | Jetzt aktualisieren (hebt Sperren auf) | Anlage |
| ⌘G | Verlauf ein/aus | Darstellung |
| ⌘D | Diagnose ein/aus | Darstellung |
| ⇧⌘M | Mini-Fenster | Darstellung |
| ⌘, | Einstellungen | App |

Nackte Pfeiltasten sind auf beiden Plattformen bewusst **nicht** belegt (sie gehören Scroll-Ansichten, Reglern und
der Tastaturnavigation); unter Windows gilt Strg+↑/↓.

### 9.3 Darstellung und Leistung

- Farben/Schriften kommen aus `ThemeStyle` (Umgebung `\.klimaTheme`), Karten über `.klimaCard`, Leuchten über
  `.klimaGlow`. Keine fest verdrahteten Farben in Ansichten.
- Liquid Glass (`.glassEffect`) nur hinter `#available(macOS 26, *)`, darunter `.ultraThinMaterial`.
- **Glas-Container:** `GlassContainer` (GlassEffectContainer) liegt INNERHALB der Scroll-Ansicht der Steuerspalte und
  getrennt um die Fußzeile. Außen gezeichnet ragt Liquid Glass ohne Zuschnitt über die Fußzeile (`.clipped()`/`.mask`
  helfen nicht).
- macOS 26 lässt die Liquid-Glass-Tönung in nicht aktiven Fenstern verschwinden (Kacheln wirken blass): Systemverhalten,
  kein Fehler. Screenshots für die Prüfung immer mit aktivem Fenster machen.
- **Größe ändern:** Während das Fenster seine Größe ändert, bleibt die Fläche der Graphen eingefroren (`WindowRef.isResizing`), Graphenhöhen wachsen nur in 20-pt-Stufen, „Lebendig“ wird auf ein Drittel der Auflösung gezeichnet, Wetter-Teilchen skalieren mit der Fläche, über ~2 MP gelten 20 statt 30 Bilder je Sekunde.
- **Grafikspeicher:** Jeder Neuaufbau der Swift-Charts-Graphen und jede Animation über den ganzen Zustand kostet kurz
  ~190 MB Grafikspeicher (Metal). Darum: Graphen selten neu aufbauen (Marks in Equatable-Ansichten, eigene
  `TimelineView` alle 30 s, Hover-Ebene getrennt), der Body des Hauptfensters liest `model.state` nicht direkt, und
  animiert werden nur Ein/Aus und Umfang.
- Graphen-Reihenfarben sind neutral, weil Orange/Grün/Blau die Modi Heizen/Trocknen/Kühlen bezeichnen.
- Menüleisten-Symbol: ohne Farbe/Drehen ein einfarbiges Vorlage-Symbol; `iconTarget` zeigt Soll nur bei laufender
  Anlage und nicht beim Lüften.

### 9.4 Berechtigungen und Autostart

„Beim Anmelden starten“ läuft über `SMAppService.mainApp` (`LoginItem` in `PanelsSettings.swift`). Beim ersten Start
aus `/Applications` bzw. `~/Applications` trägt `AppDelegate` die App einmalig ein (`LoginItemDefault`, Merker
`loginItemDefaultOn`) – auch bei bestehender Einrichtung (Update). Danach ändert nur der Schalter in Einstellungen →
Allgemein den Eintrag. Unter Windows entspricht dem der vorausgewählte Setup-Haken „Mit Windows starten“ (stille
Updates schreiben ihn nicht neu).

Neustart (Sprachwechsel, geladenes Update) läuft über `AppRestart` ohne die Rückfrage „Timer laufen – beenden?“; die
Timer sind gespeichert und laufen danach weiter. Die Sprachwahl liegt in `AppleLanguages` der App.

Die App braucht „Lokales Netzwerk“ (Info.plist-Text in `build_app.sh`, zweisprachig über `InfoPlist.strings`). Mit fester Signatur-Identität fragt macOS
nach einem neuen Build nicht erneut nach Freigaben (Netzwerk, Schlüsselbund); ad-hoc-Builds fragen jedes Mal.

### 9.5 Updates (Sparkle)

- Sparkle 2 ist ein **Binärziel** in `Package.swift` (nur im `#if os(macOS)`-Block, URL + Prüfsumme wie in Sparkles
  eigener Package.swift). So steht es nicht in `Package.resolved` und bleibt Windows verborgen. Neue Version: URL und
  Prüfsumme gemeinsam ändern, Lizenztext prüfen.
- `build_app.sh` kopiert `Sparkle.framework` nach `Contents/Frameworks` (ohne XPC-Dienste, die braucht nur eine App in
  der Sandbox), setzt `@executable_path/../Frameworks` als rpath, entfernt absolute rpaths in den Build-Ordner und
  signiert von innen nach außen (Autoupdate, Updater.app, Framework, App – kein `--deep`).
- Info.plist: `SUFeedURL` (= `AppUpdate.feedMac`), `SUPublicEDKey` (aus `tools/UPDATE_PUBLIC_KEY`),
  `SUEnableAutomaticChecks`, `SUAutomaticallyUpdate` und `SUAllowsAutomaticUpdates` = an, `SUScheduledCheckInterval` =
  86400 (täglich). `AppUpdateTests` prüft, dass Kern, Skript und Schlüsseldatei zusammenpassen.
- **Immer automatisch, nie überspringen, Suche nicht abschaltbar** (Entscheidung des Autors): `AppUpdater` setzt beim
  Start `automaticallyChecksForUpdates` und `automaticallyDownloadsUpdates` auf an (eine frühere Abwahl zählt nicht).
  „Jetzt suchen …“ und das Menü nutzen `checkForUpdatesInBackground` (kein Sparkle-Dialog mit „Überspringen“);
  Status-Texte aus dem Katalog. Fassungen unter `AppUpdate.firstAutoInstallVersion` bekommen das Update im Appcast als
  `criticalUpdate` (ohne „Überspringen“).
- **Installation ab 1.2.0.0:** Das Update wird still geladen; danach erscheint ein Hinweis „Jetzt neu starten ·
  Später“. „Später“ fragt nach 24 h erneut, installiert wird spätestens beim Beenden. Kein Überspringen. Bis 1.1.0.0
  installierte der Delegate sofort und startete neu (`willInstallUpdateOnQuit` → `immediateInstallationBlock`).
- **Neustart ohne Beenden-Rückfrage:** Beim Neustart für ein Update oder einen Sprachwechsel entfällt die Rückfrage
  „Timer laufen – beenden?“ (`quitPrompt`), denn Timer sind gespeichert und laufen danach weiter. Liegt beim
  Sprachwechsel ein Update bereit, läuft der Neustart über Sparkles Weg „installieren und neu starten“.
- **Absicherung ab 1.2.0.0:** Info.plist mit `SUVerifyUpdateBeforeExtraction` und `SURequireSignedFeed` = an. Die
  Update-Datei (`updateinfo-*.xml`) wird als letzter Schritt mit dem EdDSA-Schlüssel signiert, mit
  `sign_update --verify` geprüft und danach nicht mehr verändert. Eine ungültig signierte Update-Datei ist schlimmer
  als keine: 1.1.0.0 zeigt dann einen Dialog, statt still zu installieren.
- **Beta-Kanal (nur Mac, ab 1.2.0.0):** Einstellungen → Allgemein → Updates: „Vorabversionen (Beta) erhalten“,
  Standard aus (`SettingsKey.updateBetaChannel`). Nur mit Schalter liefert `feedURLStringForUpdater:` die Beta-Datei
  `…/releases/download/beta/updateinfo-mac-beta.xml` (`AppUpdate.feedMacBeta`); ohne Schalter bleibt `SUFeedURL`.
  Die Beta-Datei enthält die neueste stabile Fassung und die neueste Beta. Solange es keine Beta gibt, existiert sie nicht (siehe 16). Schalter aus → die App bleibt auf der
  Beta bis zur nächsten stabilen Fassung.
- Windows (WinSparkle): automatische Suche bei jedem Start erzwungen, zusätzlich Suche beim Start; jedes Update ist im
  Appcast `criticalUpdate` – WinSparkle blendet dann „Überspringen“ und „Später erinnern“ aus, nur Schließen
  (= vorerst nicht) bleibt. Ein früher gespeichertes `SkipThisVersion` wird beim Start gelöscht. Ab 1.2.0.0 erscheint der
  WinSparkle-Dialog in der Sprache der App (`win_sparkle_set_lang`).
- Bedienung: Einstellungen → Allgemein → „Updates“ (Version, „Jetzt suchen …“, Status) und Menü Klimacontrol → „Nach
  Updates suchen …“. Kein Schalter. Ohne Bundle (`swift run`) ist Sparkle aus.
- **Rückmeldung nach manueller Suche:** Mac zeigt einen `NSAlert` („aktuell“ bzw. „hat nicht geklappt“) nur bei einer vom
  Nutzer ausgelösten Suche (`userInitiated`); Hintergrundsuchen bleiben still. Windows zeigt das über die
  WinSparkle-Oberfläche (`win_sparkle_check_update_with_ui`).
- Die App wird außerhalb von OneDrive zusammengesetzt und signiert: OneDrive hängt Dateiattribute an (codesign
  scheitert) und zerlegt Framework-Symlinks (Konfliktkopien wie „Sparkle 2.framework“). Nach `dist/mac` kommen nur
  DMG, ZIP und Texte.

---

## 10. Windows-App

- WPF, `net10.0-windows`, `win-x64`, self-contained, eine Datei (`PublishSingleFile`). Ausgabe: im Hauptordner nur
  `Klimacontrol.exe`, alles andere (Swift-Laufzeit, ICU, `KlimacontrolBridge.dll`) in `res\`.
- Die Version kommt aus `tools/VERSION` (MSBuild liest die Datei).
- Fenster: Hauptfenster, Schnellsteuerung am Infobereich (Strg+Alt+K, einstellbar), Mini-Fenster, Einstellungen mit
  denselben Reitern und Begriffen wie am Mac. Mica/Acrylic statt Liquid Glass.
- Ablage `%LOCALAPPDATA%\Klimacontrol` (nicht Roaming – Token/Schlüssel sollen nicht auf andere Rechner wandern).
- Geheimnisse in der Windows-Anmeldeinformationsverwaltung.
- `tools/build_windows.ps1` muss **reines ASCII** bleiben (Windows PowerShell 5.1 liest UTF-8 ohne BOM als ANSI).
- Tests: `KlimacontrolTray.Tests` (Kern-Hülle, Layout, Themen, Texte, Updates, Bridge-Vertrag) laufen in `build_windows.ps1` mit.
- Sprachen: Oberfläche deutsch und englisch aus dem Katalog des Kerns (`Localization.cs`, `{l:T …}`), Formate aus den Regionseinstellungen (`Formats.cs`); Texte vor dem Laden des Katalogs in `StartupText.cs`. Die Sprachwahl wirkt nach einem Neustart: Die App startet sich mit `--restart` selbst neu (ohne Rückfrage zu Timern). Das Setup ist zweisprachig (Deutsch/Englisch nach Anzeigesprache von Windows, kein Sprachdialog).
- **Keine Spuren des Bau-Rechners im Paket:** Die ausgelieferte `KlimacontrolBridge.dll` wird mit `-gnone`,
  `/DEBUG:NONE` und Prefix-Maps gebaut und danach mit `llvm-strip --strip-debug` von eingebetteten DWARF-Abschnitten
  befreit; .NET-Release ohne PDB, mit `PathMap`, `Deterministic` und `ContinuousIntegrationBuild`. Vor ZIP und Setup
  bricht `build_windows.ps1` ab, wenn eine exe/dll nicht x64 (`0x8664`) ist oder App-Ordner, unkomprimierte Probe oder
  Setup Benutzerordner, Benutzer- oder Rechnernamen, OneDrive-Pfade, Claude-Container, Build-Ordner oder SIDs enthalten
  (gesucht wird auch in UTF-16, LE und BE).
  Am Mac prüft `build_app.sh` dasselbe für die App. Nie aus der Claude-Desktop-App heraus bauen (MSIX-Container).
- Updates über **WinSparkle 0.9.4** (`res\WinSparkle.dll`, Prüfsumme fest im Skript) mit demselben Appcast-Format und
  Schlüssel wie Sparkle am Mac. Aktiv nur bei Installation per Setup (Uninstall-Eintrag zeigt auf den Programmordner);
  aus dem ZIP gestartet ist der Abschnitt „Updates“ ausgegraut. Das Setup ist nicht Authenticode-signiert
  (SmartScreen-Hinweis beim ersten Start); die Echtheit der Updates sichert die EdDSA-Signatur.
- `Klimacontrol.exe` ist bewusst intern komprimiert (`EnableCompressionInSingleFile=true`, Entscheidung des Autors):
  auf der Platte ~67 statt ~150 MB, das ZIP bleibt gleich groß; dafür entpackt .NET bei jedem Start alles in den
  eigenen Speicher (gemessen: Start +0,25 s, privater Speicher +61 MB, Arbeitssatz +97 MB). Nicht ohne Rückfrage ändern. Ebenfalls ohne Gewinn
  geprüft: weniger Sprachdateien (es wird nur Deutsch mitgeliefert) und Linker-Optionen für die Brücken-DLL.

### 10.1 Windows bauen (Windows 10/11, x64)

1. Visual Studio Build Tools 2022 mit C++-Werkzeugen und Windows-SDK:
   `winget install --id Microsoft.VisualStudio.2022.BuildTools -e --override "--passive --wait --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows11SDK.22621"`
2. Swift 6.4 oder neuer (getestet mit 6.4.2), Quelle https://www.swift.org/install/windows/:
   `winget install --id Swift.Toolchain -e`; danach neues Terminal, `swift --version` prüfen.
3. .NET 10 SDK: `winget install Microsoft.DotNet.SDK.10`
4. Für das Setup: Inno Setup 6, `winget install JRSoftware.InnoSetup`
5. Im Projektordner `powershell -ExecutionPolicy Bypass -File tools\build_windows.ps1` (baut und testet den
   Swift-Kern); mit `-App` entsteht die App in `dist\windows\Klimacontrol\`, `-Zip` legt ZIP und Setup daneben,
   `-Install` kopiert nach `%USERPROFILE%\Klimacontrol`.

Gebaut wird außerhalb des Projektordners (`%LOCALAPPDATA%\Klimacontrol-build`), darum funktioniert es auch in
Cloud-Sync-Ordnern. Die fertige App braucht weder Swift noch .NET installiert. Unter Windows laufen weniger
MideaKit-Tests als am Mac (zuletzt 130 statt 137), weil einige nur auf Darwin übersetzt werden (u. a.
`LANLoopbackTests`, der echte TCP-Weg gegen 127.0.0.1).

---

## 11. Tests

### 11.1 Ziele und Dateien

| Ziel | Dateien (Auswahl) |
|---|---|
| `MideaKitTests` | `TestSupport` (Vektoren, `Locked`, `TestClock`, `TestFrames`, `FakeTransport`), `MideaKitTests` (Rahmen, Antworten), `TransportTests` (Wegwahl, Sperren), `PortaSplitDeviceTests` (Gerät mit Fake-Transport), `CloudTests`, `RobustnessTests` (kaputte Rahmen), `PlatformTests` (Krypto-Vektoren, Schlüsselbund), `ConcurrencyTests`, `LANLoopbackTests` (echter TCP-Weg gegen 127.0.0.1, nur Darwin), `TestIsolationTests`, `vectors.json` |
| `KlimacontrolCoreTests` | `TestSupport` (`CoreTestCase`, `FakeDevice`, `SpyPlatform`, `MemorySettings`, `waitUntil`, `AsyncGate`), `KlimacontrolCoreTests`, `ControllerTests`, `HistoryTests` (Spalten, Kopfzeilen wörtlich, Rundläufe), `LogTextTests` (Schlüssel und deutscher Text in MideaKit gegen den Katalog, Übersetzer), `DisplayCatalogTests` (Anzeige-Katalog wörtlich), `ACControllerUITests`, `SetupTests`, `SetupFlowTests`, `TimerEnergyTests`, `EnergyPeriodTests` (Verbrauch je Zeitraum, Sommerzeit, Zählerwechsel), `AppearanceTests`, `VersionTests` (CHANGELOG-Kopf = `tools/VERSION`), `ThirdPartyNoticesTests` (Swift-Texte = `docs/THIRD_PARTY_NOTICES.md`), `AppUpdateTests` (Feed, Intervall und Schlüssel passen zu `build_app.sh`), `ReleaseProtectionTests` (D1-Werte wörtlich, Abschnitt 14.1), `ReleaseScriptTests` (startet `tools/test_make_release.py`, nur Mac), `LocalizerTests`, `StringsCatalogTests`, `FormatProfileTests` (liest `Tests/Shared/rounding-table.json`), `AppVersionTests`, `ChangelogParityTests`, `SettingsLocaleTests`, `DisplayNamesTests`, `AppLanguageTests`, `HistoryLanguageTests`, englische Teststände je Bereich (`MessageEnglishTests`, `PromptEnglishTests`, `OptionsEnglishTests`, `StatusEnglishTests`, `SetupEnglishTests`), `EnglishLeakTests` (kein Deutsch im englischen Katalog und in allen gesammelten Anzeigetexten, Pseudo-Sprache findet Texte am Katalog vorbei, Protokollzeilen folgen der Sprache der Oberfläche), `AppSourceTextsTests` (kein deutscher Text in `Sources/KlimacontrolApp`) |
| `KlimacontrolBridgeTests` | `BridgeDisplayTests` (Katalog-Felder), `BridgeContractTests`: jedes Feld des echten Schnappschusses steht in `bridge-muster.json` (Gegenrichtung zu `VertragTests`); `BridgeCommandTests`: Parametertypen, Meldungen, Befehlsnamen gegen `Cmd` in C#; `BridgeEnergyTests` (`kc_energy_json`), `BridgeLocaleTests` (`kc_set_locale`, `kc_strings_json`, Befehle `language`/`currency`), `BridgeEnglishTests`, `BridgeWhatsNewTests` |
| Windows (C#) | `CoreTests`, `LayoutTests`, `ThemeTests`, `AppearanceTextTests` (Darstellung wie am Mac), `LocalizationTests` (Textschlüssel und Katalog), `VertragTests` (Schnappschuss, Befehlsnamen, Anzeige-Katalog, keine eigenen Listen/Grenzen in der Oberfläche) |

Stand zuletzt (nach Release 1.2.0.0): Mac 584 Tests (MideaKit 137, Kern 406, Bridge 41; 2 übersprungen, beide bewusst: Live-Scan, echter
Schlüsselbund). Windows zuletzt 577 Swift + 278 C# (MideaKit 130, Kern 404, Bridge 43). Zeitzonen-Tests nehmen eine feste Zone (`TimeZone(identifier:)`) oder die Ortszeit über
`Calendar.current.timeZone`. Die Rundungstabelle `Tests/Shared/rounding-table.json` liest Swift (`#filePath`, keine
Ressource) und C# gemeinsam.

### 11.2 Isolation – Tests fassen nichts Echtes an

- **Schlüsselbund:** In Testprozessen schaltet `TestEnvironment.isRunningTests` automatisch auf Speicher (auch unter
  Windows, erkannt am Prozess `…-test-runner.exe`/xctest). Konto über `CloudAccountStore` im Speicher.
  `testSecretStoreRoundTrip` prüft den echten Speicher nur mit `KLIMACONTROL_REAL_SECRETS=1`.
- **Protokoll:** `KLIMACONTROL_LOG_DIR`, sonst `$TMPDIR/KlimacontrolTests/`.
- **Dateien/Einstellungen:** je Test eigener Temp-Ordner (`CorePaths(directory:)`) und `MemorySettings`; einzig
  `testWorksWithRealUserDefaults` nutzt echte UserDefaults in einer eigenen Suite und entfernt sie danach.
- **Netz:** Anlage nachgebildet (`FakeDevice`, Fake-Transporte); kein Netz außer 127.0.0.1.
- **Zeit:** auf Bedingungen warten (`waitUntil`, `settle(c, commands:)`) statt fester Pausen; Zeitpunkte als
  Parameter (`now:`) übergeben; Ortszeit nur über `Calendar.current` (Abschnitt 12).

### 11.3 Testvektoren

`Tests/MideaKitTests/vectors.json` (AES-, Hash-, Discovery-Vektoren) ist gegen msmart-ng erzeugt
(`tools/make_vectors.py` führt zusammen und behält von Hand ermittelte Vektoren). **Nie einen Vektor ändern, damit
ein Test grün wird** – passt ein Vektor nicht, ist der Code falsch. Die Datei wird über `#filePath` gelesen, nicht als
Ressource (darum `exclude` in `Package.swift`). PortaSplit-Antworten in den Tests sind echten Antworten
nachgebildet, mit erfundenen Kennungen.

### 11.4 Neuer Test – Muster

1. Testklasse von `CoreTestCase` ableiten (Temp-Ordner, `MemorySettings`, `SpyPlatform`, `FakeDevice`,
   `makeController()`/`makeConnected()`); die echte Zugangsdaten-Prüfung ist dort gesperrt (`XCTFail`).
2. Aktion auslösen, mit `waitUntil`/`settle` auf den Zustand warten.
3. Zustand **und** gesendete Befehle prüfen (die Fakes zeichnen Befehle auf).
4. Kein `sleep`, keine echte Uhr ohne Not (`CoreDependencies(now:)`), keine echten Pfade. Langsame Antworten der Anlage
   mit `AsyncGate` nachbilden, das der Test selbst öffnet. Achtung: `settle` kehrt sofort zurück, wenn noch kein Task
   läuft – nach `update()`/`setPower()` erst auf den Zähler des Fakes warten. Entprellzeit und Zonen-Abstand setzt
   `makeController()` klein (`debounceDelay` 50 ms, `zoneGap` 0,2 s; die Apps behalten 700 ms und 2 s); wer die Länge
   prüft, setzt den Wert danach selbst.

---

## 12. Code-Regeln

- Swift 6, strikte Nebenläufigkeit. `any` vor existenziellen Typen. `@unchecked Sendable` und `nonisolated(unsafe)`
  nur mit Kommentar, was schützt. Gemeinsamer Zustand über `Mutex` (Synchronization) statt NSLock; `@unchecked
  Sendable` bleibt nur für Zustand auf einer seriellen Queue (Beispiel: `PortaSplitDevice` – Zustand im `Mutex`
  `shared`, Transport nur auf der seriellen `queue`).
- Fehler werden über ihren **Typ** ausgewertet (`MideaError`, `ConnectionReason`, `PathFailure`, `CloudError`), nie über Meldungstexte;
  Texte dienen nur Anzeige und Protokoll. Einzige Ausnahme: Antworttexte von Midea selbst (`CloudError.kind`).
- Der LAN-Transport ist **bewusst blockierend** (serielle Queue, `Thread.sleep` für die Protokoll-Pausen). Ein
  async-Umbau ist ein eigenes Vorhaben mit Live-Tests, kein Nebenbei-Refactoring.
- Apple-only-APIs (Security, CryptoKit, CommonCrypto, Darwin, `String(format: "%@")` …) in MideaKit/Kern nur hinter
  `#if canImport(…)`/`#if os(Windows)` mit Gegenstück – der Kern muss unter Windows bauen.
- **Neue Funktion immer in dieser Reihenfolge:** Kern (Logik + Tests) → Bridge (Schnappschuss-Feld bzw. Befehl) →
  Mac-Oberfläche → Windows-Oberfläche.
- **Kommentare: so wenig wie möglich, so viel wie nötig.** Nur das *Warum*, das im Code nicht sichtbar ist
  (Protokoll-Eigenheit, Plattform-Fallstrick, Sicherheitsgrund, gemessener Grenzwert); kurze `///`-Doku an
  öffentlichen Typen, wenn der Name nicht reicht. Keine internen Ticket-/Review-Kennungen, keine Verlaufsangaben
  („früher …“, Daten), keine Personennamen, keine Nacherzählungen, kein auskommentierter Code. `// MARK: -` nur bei
  wirklich mehreren Abschnitten.
- Dateien: UTF-8, **LF**, 4 Leerzeichen (`.editorconfig`, `.gitattributes`). CRLF macht die zsh-Skripte unbrauchbar.
- Keine `.swift`-Dateien mit Leerzeichen oder `-` im Namen: Die Skripte halten solche für Sync-Konfliktkopien
  (`Crypto-DESKTOP-1234.swift`, `Crypto 2.swift`) und brechen ab, weil sie sonst mitkompiliert würden (doppelte Typen).
- Neue Abhängigkeiten nur mit Lizenzprüfung und Eintrag in `docs/THIRD_PARTY_NOTICES.md` **und**
  `ThirdPartyNotices.swift` (Test vergleicht wörtlich). `Package.resolved` wird eingecheckt, nicht von Hand gepflegt.
- Neue Zeitstempel ISO 8601 mit Zone; Migrationen bekommen ein Ablaufdatum im Code.
- **Ortszeit nur über `Calendar.current`** (bzw. `Calendar.current.timeZone`), nie `TimeZone.current` oder
  `Date.FormatStyle` für Uhrzeiten: Unter Windows liefern diese GMT, und auf keiner Plattform folgt `TimeZone.current`
  einer gesetzten Standardzone (`NSTimeZone.default`, die die Bridge unter Windows beim Start setzt). Gespeicherte
  Formatierer übernehmen die Zone bei jedem Zugriff (`HistoryLog.followLocalZone`). `HistoryTests` sucht
  `TimeZone.current` in den Quellen; Tests mit Ortszeit setzen `NSTimeZone.default` und stellen sie zurück.

---

## 13. Oberfläche und Texte

- Sprachen: **Deutsch und Englisch** (Regeln in 13.2), ohne Fachjargon; Deutsch mit Du-Form in Hilfetexten, Englisch
  sachlich mit „you“ in Hilfetexten. Meldungen: „Was ist passiert. Was tun. (code)“ bzw. „What happened. What to do.
  (code)“. Jeder neue Text entsteht in beiden Sprachen.
- Mac und Windows haben **gleiche Optionen, Texte, Standardwerte und Reihenfolgen**; plattformtypische Umsetzung ist
  erlaubt (Liquid Glass ↔ Mica/Acrylic, Menüleiste ↔ Infobereich, ⌘ ↔ Strg) – in beiden Sprachen.
- Barrierefreiheit: VoiceOver- bzw. UIA-Beschriftungen an allen Bedienelementen, Zustände nie nur über Farbe,
  Kontrast-Thema erfüllt WCAG AA, „Bewegung reduzieren“ des Systems wird beachtet.

### 13.1 Begriffe (Glossar – verbindlich auf beiden Plattformen)

| Richtig | Nicht |
|---|---|
| Anlage | Gerät, Klima, AC |
| Midea-Konto | Cloud-Konto, Account |
| Zugangsdaten (Token und Schlüssel) | Credentials, Keys |
| Sicherung | Backup (nur im Dateiformat) |
| Schwenken | Swing |
| Anzeige (am Gerät) | Display |
| Außengerät leise | Leise außen (nur als kurze Zonen-Beschriftung am Lüfter) |
| Leistung begrenzen | Rate select |
| Selbstreinigung (als kurze Kachel: Reinigung) | Clean |
| Adresse neu suchen | Neu verbinden, Relocate |
| Verlauf | Historie, Graph |
| Diagnose | Debug |
| Anlagen-ID, Name der Anlage, Kennung der Anlage, Zähler der Anlage | Geräte-ID, Gerätename, Gerätekennung, Gerätezähler |
| Ausführliches Protokoll | Debug-Protokoll |
| Kurzinfo | Tooltip |
| Darstellung | Design, Theme |
| Update (neue Version der App) | Aktualisierung (meint: Werte der Anlage neu lesen) |
| Lizenzen | Third-Party, Notices |
| WLAN · Cloud · Automatisch | LAN, Remote |
| Einfach · Alles | Basic, Expert |

„PortaSplit“ nur für das Midea-Gerät (Marke von Midea); die App heißt **Klimacontrol** (mit c).

**Englisch** (gleich verbindlich; US-Schreibung, z. B. „color“, „license“):

| Deutsch | Englisch | Nicht verwenden |
|---|---|---|
| Anlage | air conditioner | device, appliance, unit, AC |
| Anlagen-ID · Name der Anlage · Kennung der Anlage · Zähler der Anlage | air conditioner ID · air conditioner name · air conditioner identifier · air conditioner's meter | device ID, device name, appliance code |
| Midea-Konto | Midea account | cloud account, login |
| Zugangsdaten (Token und Schlüssel) | credentials (token and key) | keys, secrets, login data |
| Zugangsdaten sichern | Back up credentials | Export keys |
| Sicherung · Sicherung einlesen | backup · Restore backup | export file, import keys |
| Einrichtung · Neu einrichten | setup · Set up again | pairing, reset, re-pair |
| Adresse neu suchen | Find address again | reconnect, relocate |
| Ein · Aus · Einschalten · Ausschalten | On · Off · Turn on · Turn off | power on, enable |
| Kühlen · Heizen · Trocknen · Lüften · Auto | Cool · Heat · Dry · Fan · Auto | dehumidify, ventilate |
| Soll · Raum · Außen | Target · Room · Outdoor | set point, inside, outside |
| Lüfter · Leise · Niedrig · Mittel · Hoch · Max · Auto | Fan · Quiet · Low · Medium · High · Max · Auto | speed 1–5 |
| Schwenken | Swing | oscillate, louver |
| Anzeige (am Gerät) | Display | screen, LED |
| Außengerät leise (kurz am Lüfter: Leise außen) | Quiet outdoor unit (short: Quiet outdoor) | silent mode |
| Leistung begrenzen | Limit power | rate select, power cap |
| Selbstreinigung (kurze Kachel: Reinigung) | Self-cleaning (short tile: Self-clean) | auto clean |
| Frostschutz · Ionisierer · Eco · Turbo · iECO | Frost protection · Ionizer · Eco · Turbo · iECO | freeze guard, purifier |
| Timer · Ausschalten in … · Einschalten um … | timer · Turn off in … · Turn on at … | schedule, sleep timer |
| Szene | scene | preset, profile, favorite |
| Verlauf | History | log, graph, chart |
| Verbrauch · Strompreis · Kosten · Leistung | consumption · electricity price · cost · power | usage, tariff, rate, wattage |
| Währung | currency | unit |
| Diagnose | Diagnostics | debug |
| Protokoll · Ausführliches Protokoll | Log · Detailed log | debug log, verbose log |
| Kurzinfo | tooltip | hint, popup |
| Darstellung · Thema | Appearance · theme | design, skin |
| Einfach · Alles | Simple · All | basic, expert, advanced |
| Update (neue Version der App) | update | upgrade |
| Aktualisieren (Werte der Anlage neu lesen) · Jetzt aktualisieren | Refresh · Refresh now | reload, sync, update |
| Vorabversion (Beta) | pre-release (beta) | preview, nightly |
| WLAN · Cloud · Automatisch · Nur WLAN · Nur Cloud (unterwegs) | Wi-Fi · Cloud · Automatic · Wi-Fi only · Cloud only (away) | LAN, WLAN, WiFi, local, remote |
| belegt · antwortet nicht | busy · not responding | blocked, offline |
| Einstellungen · Allgemein · Verbindung · Anlage · Protokoll · Lizenzen | Settings · General · Connection · Air conditioner · Log · Licenses | Preferences, third party, notices, credits |
| Sprache · Systemsprache | Language · System language | locale |
| Mini-Fenster | mini window | widget, compact view |
| Menüleiste (Mac) · Infobereich (Windows) · Schnellsteuerung | menu bar · notification area · quick controls | tray, system tray, status bar |
| Mitteilung | notification | toast, alert |
| Rückfrage · Hinweis · Meldung | confirmation · notice · message | popup, dialog box |

Englische Texte: Großschreibung wie im Satz (auch auf Knöpfen und Menüs, auf beiden Plattformen gleich), direkte
Anrede mit „you“ nur in Hilfetexten, Anführungszeichen “…”, Auslassung „…“ als ein Zeichen. Meldungen nach demselben
Muster: „What happened. What to do. (code)“. „Klimacontrol“ und „PortaSplit“ bleiben unverändert.

### 13.2 Sprachen und Formate

| Thema | Regel |
|---|---|
| Sprachen | Deutsch und Englisch; der Katalog kann weitere tragen |
| Automatik | Systemsprache Deutsch (jede `de-*`) → Deutsch, jede andere → Englisch |
| Rückfall | Englisch (fehlt ein Text in der gewählten Sprache, gilt der englische) |
| Sprachwahl | Einstellungen → Allgemein, ganz oben: Systemsprache · Deutsch · English; wirkt nach einem Neustart der App |
| Ablage der Wahl | Mac: `AppleLanguages` der App (dieselbe Einstellung wie Systemeinstellungen → Sprache & Region → Apps); die Sprache beim Start ergibt sich aus `Bundle.preferredLocalizations(from:forPreferences: nil)` (die `.lproj`-Ordner mit `InfoPlist.strings` in `build_app.sh` machen `de` und `en` für macOS sichtbar); Windows: `SettingsKey.language` im Kern |
| Formate | Zahlen, Uhrzeit (12/24 h) und Datum nach den Regionseinstellungen des Systems, unabhängig von der Sprache (`FormatProfile`) |
| Währung | Freitext, 1–3 Zeichen (Buchstaben oder Währungszeichen, keine Ziffern), Standard „€“, immer nachgestellt („0,30 €“, „0.30 CHF“); Strompreis 0–1000 |
| Versionshinweise nach einem Update | in der Sprache der Oberfläche aus `CHANGELOG.md` bzw. `CHANGELOG.en.md`; Fassungen vor 1.2.0.0 nur deutsch mit dem Hinweis „Release notes for this version are available in German only.“ |
| Bleibt deutsch | Update-Hinweise im Appcast (Sparkle/WinSparkle vor dem Update), README, LIESMICH; der Release-Text auf GitHub ist deutsch mit einem englischen Abschnitt aus `CHANGELOG.en.md` |
| Nicht übersetzt | Technische CSV-Form, Datenbank-Spalten, Fehlercodes in Klammern, die Lizenztexte selbst (englische Originale), Bridge-Befehlsnamen, bereits geschriebene Protokollzeilen (das Protokoll folgt der Sprache der Oberfläche, 7.9) |
| Mac-Paket | Zweisprachige Info.plist-Texte (`InfoPlist.strings`) und zweisprachiger DMG-Hintergrund; Mac-Oberfläche ohne eigene Texte (`AppSourceTextsTests`) |
| Testsprache | Pseudo-Sprache nur mit `KLIMACONTROL_PSEUDO=1` (englischer Text mit Akzenten, eingerahmt und verlängert), zum Finden vergessener und abgeschnittener Texte; nie für Nutzer sichtbar |

**Katalog und Ablauf:**

1. Alle Anzeigetexte stehen in **einem** Katalog `l10n/Localizable.xcstrings` (JSON im Format der Apple-String-
   Catalogs, Quellsprache `en`). Schlüssel `bereich.teil.name` (z. B. `settings.language.title`), Platzhalter benannt
   als `{name}`, Mehrzahl über `variations.plural` (`one`/`other`) mit `{count}`.
2. Nach jeder Änderung am Katalog `python3 tools/sync_strings.py` ausführen. Es prüft den Katalog (beide Sprachen da,
   gleiche Platzhalter, gültige Schlüssel), schreibt ihn sortiert zurück und erzeugt
   `Sources/KlimacontrolCore/StringsData.swift` mit typisierten Zugriffen `L.Bereich.Teil.name` bzw.
   `L.Bereich.Teil.name(platzhalter:)`. `StringsData.swift` nie von Hand ändern; `StringsCatalogTests` vergleicht
   sie wörtlich mit dem Katalog.
3. **Neue Texte immer in beiden Sprachen** und immer über den Katalog – auch Windows-only-Texte (Windows liest die
   Tabelle über `kc_strings_json`, XAML `{l:T …}`, C# `L.T(…)`). Ein Text nur auf Deutsch oder nur auf Englisch bricht
   den Generator.
4. Der Kern formatiert Zahlen und Zeiten selbst über `Fmt` und `FormatProfile` (nie `Locale.current`,
   `Date.FormatStyle` oder `DateFormatter` ohne Profil – unter Windows liefern diese falsche Werte). Mac: Profil aus
   `Locale.autoupdatingCurrent`; Windows: aus `CultureInfo` über `kc_set_locale` vor `kc_init`.
5. Die Sprache wird **einmal beim Start** festgelegt (`Localizer.configure`) und gilt für den ganzen Prozess. Tests
   wählen eine Sprache nur über den Test-Haken des `Localizer`; ohne Festlegung gilt Deutsch.
6. Texte, die heute in MideaKit entstehen (z. B. `CloudError.what/todo`, Modus- und Lüfternamen), werden im Kern
   (`UserMessage`, Anzeige-Katalog) übersetzt; MideaKit ruft sie über `LogText.t` mit Katalogschlüssel und deutschem Text auf (7.9).
7. Neue Texte bekommen im Katalog einen `comment` (wo sie stehen), damit sie sich ohne Code übersetzen lassen.
8. **Katalog-Teile:** Arbeiten mehrere Agenten gleichzeitig, schreibt jeder nur in seine Datei `l10n/parts/<name>.json`
   (Aufbau wie der Hauptkatalog); `python3 tools/sync_strings.py` prüft Hauptkatalog und Teile zusammen,
   `--add <teil.json> <schlüssel> <de> <en> <kommentar>` legt einen einfachen Text an, und `python3 tools/sync_strings.py
   --merge-parts` führt die Teile in den Hauptkatalog (Teile kommen in den Papierkorb). Im Normalbetrieb bleibt
   `l10n/parts/` leer (nur `.gitkeep`).
9. Rohtext aus MideaKit entsteht über `LogText.t` in der Sprache der Oberfläche (Protokoll, Detailzeile); Anzeige immer über Kern und Katalog. Neuer Text im Englischen:
   Glossar oben, Satz-Großschreibung, kein deutsches Wort oder Zeichen – `EnglishLeakTests` prüft den ganzen Katalog.

---

## 14. Versionen, CHANGELOG, Ausgabe, Signatur

- Version steht **nur** in `tools/VERSION` und im obersten CHANGELOG-Eintrag (`VersionTests`). Die App zeigt nach einem Update
  den CHANGELOG-Abschnitt der neuen Version („Neu in Klimacontrol …“ mit OK). Darum nach **jeder** Änderung an
  `CHANGELOG.md` `python3 tools/sync_release_notes.py` ausführen (schreibt `ReleaseNotesData.swift`;
  `ReleaseNotesTests` vergleicht wörtlich) – auch nach dem Datum beim Release, vor dem Bau. Vier Stellen,
  Hauptversion.Funktionen.Fehlerbehebung.Bau (seit 1.0.0.0): neues Paket ohne Änderung für Nutzer (z. B. neu
  signiert) → `a.b.c.d+1`, Fehlerbehebung → `a.b.c+1.0`, Neues → `a.b+1.0.0`, Änderungen, die Einrichtung oder Daten
  unbrauchbar machen → `a+1.0.0.0`. Dieselbe Zeichenkette überall (Info.plist, Windows-Dateiversion, WinSparkle,
  Appcast, Dateinamen), Release-Tag `v<Version>` (z. B. `v1.0.0.0`).
  Betas: `tools/VERSION` bleibt rein numerisch (Zielversion); `tools/build_app.sh --beta <n>` baut `<Version>b<n>`
  (z. B. `1.2.0.0b1`), Tag `v<Version>b<n>`. Reihenfolge: `1.1.0.0` < `1.2.0.0b1` < `1.2.0.0b2` < `1.2.0.0` (Sparkle
  wertet einen Buchstaben-Anhang als älter; der Kern vergleicht gleich, `AppVersion`). Eine Beta gibt der Autor frei
  wie ein Release; ein Windows-Setup ist dafür nicht nötig.
- **Hochgezählt wird nur bei der Release-Freigabe**, und die gibt allein der Autor. Bis dahin sammeln sich alle
  Änderungen beider Rechner im obersten CHANGELOG-Abschnitt der laufenden Entwicklungsversion (`tools/VERSION` frisch
  lesen, den vorhandenen Abschnitt ergänzen, keine neue Version anlegen).
- `CHANGELOG.md`: neueste Version oben, `## [X.Y.Z.W] – JJJJ-MM-TT` (in Arbeit: `## [X.Y.Z.W] – in Arbeit`), Abschnitte „Hinzugefügt“, „Geändert“, „Behoben“,
  „Entfernt“; Deutsch, aus Sicht der Nutzer (was ist anders, was muss man tun). Plattformspezifisches beginnt mit
  „Windows:“ bzw. „Mac:“. Formulierung nach dem CHANGELOG-Stil (14.3). Alte Einträge nie umschreiben.
- **Ab 1.2.0.0 (Mehrsprachigkeit) zusätzlich `CHANGELOG.en.md`:** dieselben Versionen, Abschnitte (`### Added`,
  `### Changed`, `### Fixed`, `### Removed`) und Zeilen in derselben Reihenfolge auf Englisch, mit denselben
  Plattform-Präfixen („Mac:“, „Windows:“). Wer `CHANGELOG.md` ändert, ändert `CHANGELOG.en.md` im selben Schritt mit;
  `sync_release_notes.py` bettet beide ein, und „Neu in Klimacontrol …“ nach einem Update zeigt die Sprache der
  Oberfläche. Fehlt eine Version auf Englisch (Fassungen vor 1.2.0.0), erscheint sie deutsch mit dem Hinweis
  „Release notes for this version are available in German only.“ Der Appcast bleibt deutsch; der Release-Text auf GitHub bekommt unter dem deutschen Teil
  einen englischen Abschnitt aus `CHANGELOG.en.md`. Der Kopf von `CHANGELOG.en.md` lautet `## [X.Y.Z.W] – in progress`
  bzw. mit Datum; `VersionTests` prüft ihn gegen `tools/VERSION`.
- Mac-Ausgabe `dist/mac/`: `Klimacontrol-<Version>-mac.dmg` (Installation und Sparkle-Updates; darin nur App und
  Verknüpfung „Programme“ vor einem Hintergrund mit Anleitung; die Lizenzhinweise stehen in der App). Die
  Finder-Ansicht schreibt das Bauwerkzeug **dmgbuild** (MIT, Versionen und Prüfsummen fest in `tools/dmg_requirements.txt`) direkt: Per
  AppleScript gesetzte Hintergründe und Symbolgrößen speichert der Finder seit macOS 26 nicht mehr. dmgbuild liegt in
  einer eigenen Python-Umgebung im Build-Ordner (`venv-dmg`), wird beim ersten Bau einmal aus PyPI installiert und
  kommt nicht ins Paket. Die `hdiutil`-Hinweise auf abgekündigte Schalter stammen von dmgbuild.
  Daneben `Klimacontrol-<Version>-mac.zip` (mit `ditto`, ohne `__MACOSX`), `LIESMICH.txt`, Lizenzhinweise.
  Windows-Ausgabe `dist/windows/Klimacontrol/`, ZIP und `Klimacontrol-Windows-<Version>-Setup.exe`. `releases/v<Version>/`
  (gitignoriert) stellt `make_release.py` am Mac aus beiden zusammen. Ausgaben nie von Hand ändern; keiner legt etwas in den
  Ausgabeordner der anderen Plattform.
- **Signatur** (`build_app.sh`): `KLIMACONTROL_SIGN_IDENTITY`, sonst automatisch „Developer ID Application“ vor
  „Apple Development“ vor ad hoc; Hardened Runtime und Zeitstempel. „Developer ID“ = Weitergabe an andere Macs
  (danach notarisieren), „Apple Development“ läuft ohne Warnung nur auf eigenen, registrierten Macs, ad hoc nur lokal.
- **Notarisierung:** `KLIMACONTROL_NOTARY_PROFILE=<Profil>`; das Profil legt man einmal mit
  `xcrun notarytool store-credentials` an (app-spezifisches Passwort gibt der Mensch selbst ein). Dauer: Minuten bis
  zu einer halben Stunde. Danach Ticket anheften (`stapler`) und ZIP neu bauen, dann das DMG bauen, signieren,
  notarisieren und heften – erledigt das Skript. Übliches Profil des Autors: `klimacontrol`. Die LIESMICH nennt den
  Schritt „Dennoch öffnen“ nur bei nicht notarisierten Paketen.
- Zertifikate, private Schlüssel und Notarisierungs-Profile liegen nur beim Bauenden, nie im Repo.

### 14.1 Updates und Release

- Mac (Sparkle) und Windows (WinSparkle) lesen je einen Appcast, der **als Datei am GitHub-Release** hängt:
  `…/releases/latest/download/updateinfo-mac.xml` bzw. `updateinfo-win.xml` (`AppUpdate`; die Namen beginnen mit
  „u“, damit GitHub sie in der Dateiliste unten einsortiert). „latest“ ist das neueste
  Release, das kein Vorabrelease ist.
- **Ein** EdDSA-Schlüsselpaar für beide Plattformen: öffentlich in `tools/UPDATE_PUBLIC_KEY`, privat im Schlüsselbund
  des Autors (Konto `klimacontrol`, angelegt mit Sparkles `generate_keys --account klimacontrol`). Geht der private
  Schlüssel verloren, bekommen installierte Fassungen keine Updates mehr – er muss gesichert sein. Nie ins Repo.
- Ablauf: `tools/build_app.sh` (mit Notarisierung) · Windows `tools\build_windows.ps1 -Zip` (legt auch das Setup an) ·
  `python3 tools/make_release.py` · D3 abarbeiten · Release `v<Version>` anlegen (`--publish`) · danach
  `python3 tools/make_release.py --check-published` (D3/8).
- Ablauf Beta (nur Mac): `tools/build_app.sh --beta <n>` · Notarisierung · `python3 tools/make_release.py --beta <n>` ·
  D3 · `--publish`. Die stabile Fassung für die Beta-Update-Datei kommt aus `--stable-feed <Datei>`, sonst aus dem
  höchsten lokalen `releases/v<a.b.c.d>/`, sonst nur mit `--fetch-stable` aus dem Netz.
- Am Release hängen **nur das Mac-DMG und das Windows-Setup** (dazu die beiden `updateinfo-*.xml` und Prüfsummen); die ZIPs aus den
  Bauskripten sind für Tests und Handbetrieb. `make_release.py` prüft zuerst, dass DMG und App darin notarisiert und
  geheftet sind (`stapler validate`, `spctl` „Notarized Developer ID“), und bricht sonst ab, ebenso ohne Setup.
- `make_release.py` kopiert DMG und Setup nach `releases/v<Version>/`, signiert beide, schreibt `updateinfo-mac.xml` und `updateinfo-win.xml` (Versionshinweise aus dem CHANGELOG ohne die Zeilen der anderen Plattform),
  `SHA256SUMS.txt` und `RELEASE_NOTES.md` (Beschreibungstext mit Download-Tabelle, wird nicht angehängt).
- GitHub erkennt Releases nicht von selbst: den Ordnerinhalt im Release-Formular hochladen (Tag `v<Version>` auf
  `main`, „latest“, kein Vorabrelease) oder `--publish` (GitHub CLI `gh`, angemeldet) – nur auf ausdrücklichen Auftrag.
- **Beta-Releases (nur Mac):** jede Beta ist ein eigenes Vorabrelease `v<Version>b<n>` auf einem Commit des
  Entwicklungszweigs. Das feste Vorabrelease „beta“ (Tag `beta`) gibt es erst mit der ersten Beta: `--publish --beta <n>` legt
  es an und ersetzt dort `updateinfo-mac-beta.xml` (neueste stabile + neueste Beta). Ein stabiles Release legt „beta“ nicht
  an, erzeugt und lädt keine Beta-Datei; `--check-published` prüft die Beta-Adresse nur, wenn „beta“ existiert, sonst
  Hinweis „noch kein Beta-Kanal“. Die öffentliche `updateinfo-mac.xml` wird für eine Beta nie angefasst.
- Veröffentlicht ist 1.2.0.0 (08.11.2026): `latest` trägt genau fünf Dateien (Mac-DMG, Windows-Setup, `updateinfo-mac.xml`,
  `updateinfo-win.xml`, `SHA256SUMS.txt`); v1.1.0.0 bleibt bestehen. Das frühere Vorabrelease „beta“ samt Tag wurde
  gelöscht, weil es noch keine Beta gab.
- **Signatur der Update-Dateien:** `make_release.py` signiert DMG, Setup und zuletzt die `updateinfo-*.xml`, prüft
  jede Signatur (`sign_update --verify`) und verändert die Dateien danach nicht mehr. Zum Schluss prüft
  `verify_release_dir()` den Ordner vollständig (D3/7, läuft automatisch). Bestehende Release-Ordner werden nie
  gelöscht, sondern in `…alt-<Zeitstempel>` umbenannt.
- **Selbsttest:** `python3 -I tools/test_make_release.py` (auch als `ReleaseScriptTests`) läuft mit Probedateien und
  einem nachgebildeten `sign_update`, ohne Schlüssel, Netz oder GitHub.
- **Testaufbau D3/1 und D3/3:** `tools/update_test_feed.py` stellt eine lokale, echt signierte Update-Datei bereit, mit der
  das originale DMG der vorigen Fassung auf die neue (bzw. die Probe-Fassung) aktualisiert wird; Aufruf und Optionen
  stehen im Kopf des Skripts.
- **Testaufbau D3/2 und D3/3 (Windows):** `tools/update_test_feed_win.py` (Aufruf im Kopf) liefert Setup und signierte `updateinfo-win.xml` auf `http://127.0.0.1:<port>/`; `tools/check_windows_upgrade.ps1` hält den Zustand vor und nach dem Update fest und vergleicht. 1.1.0.0 kennt keinen Test-Feed: 1.1.0.0 → 1.2.0.0 wird mit dem Setup und den WinSparkle-Kommandozeilenschaltern ausgelöst. Ab 1.2.0.0 gilt der echte Weg über `KLIMACONTROL_UPDATE_TEST_FEED`. WinSparkle prüft die Signatur des Setups, nicht die der Update-Datei. Ein über WinSparkle geladenes Setup zeigt keine SmartScreen-Warnung, nur der Browser-Download bei der Erstinstallation.

#### Schutz der installierten Fassungen (Pflicht bei jedem Release)

Installierte Fassungen ab 1.1.0.0 aktualisieren sich nur, solange diese Punkte stimmen.

**D1 – nie ändern:**

| Punkt | Mac | Windows |
|---|---|---|
| Update-Adresse | `…/releases/latest/download/updateinfo-mac.xml` | `…/releases/latest/download/updateinfo-win.xml` |
| „latest“ | immer ein stabiles Release mit beiden Dateien | ebenso |
| Schlüssel, Signatur | derselbe EdDSA-Schlüssel (`tools/UPDATE_PUBLIC_KEY`); dieselbe Developer-ID (Team wie in der Signatur von 1.1.0.0) | derselbe EdDSA-Schlüssel |
| Kennungen | `de.mlafx.klimacontrol`, `Klimacontrol.app` | `AppId {1EAA2BD1-F86E-420F-A62C-4057C87B34F8}`, `{localappdata}\Programs\Klimacontrol`, Registry-Pfad von WinSparkle |
| Mindest-System | macOS 15.0 | Windows 10 x64 (`MinVersion=10.0`, `ArchitecturesAllowed=x64compatible`) |
| Update-Datei | gültig signiert oder gar nicht | – |
| Releases, Tags | nie verschieben, löschen, umbenennen | ebenso |

**D2 – für Nutzer spürbar, gehört in den CHANGELOG:** z. B. Englisch bei nicht deutschem System, Formate nach
Region, Mac „Jetzt neu starten · Später“.

**D3 – Prüfungen vor dem Release** (jede abhaken, Ergebnis in die Übergabe):

1. Mac: vorige Fassung (originales DMG) → neue Fassung. Update-Adresse nur zum Test umleiten
   (`defaults write de.mlafx.klimacontrol SUFeedURL …`, danach `defaults delete de.mlafx.klimacontrol SUFeedURL`),
   lokale, echt signierte Update-Datei. Prüfen: still installiert, Neustart, „Neu in …“, Einstellungen erhalten, keine
   neuen Rückfragen. Ablauf: „Mac-Update-Prüfung Schritt für Schritt“ unten.
2. Windows: vorige Fassung → neue Fassung (1.1.0.0 → 1.2.0.0 über WinSparkle-Schalter, später über den Test-Feed): kein Sprachdialog im Setup, gleicher Ordner, kein zweiter
   Uninstall-Eintrag, Autostart unverändert.
3. Neue Fassung → Probe-Fassung (nächste Bau-Nummer): „Jetzt neu starten · Später“; eine unsignierte Update-Datei wird
   abgelehnt.
4. Beta-Weg: erste Beta von Hand, zweite über den Kanal, dann die stabile Fassung; die öffentliche Update-Datei bleibt
   unverändert (Prüfsumme vorher/nachher).
5. Notarisierung einer Beta-Version (`…b1`) angenommen, sonst Rückfall auf eine rein numerische Vorabnummer.
6. Automatische Tests grün: D1-Werte (`ReleaseProtectionTests`), Signatur, stabiler Eintrag in der Beta-Datei,
   Versionsvergleich (`ReleaseScriptTests` bzw. `tools/test_make_release.py`), CHANGELOG deutsch/englisch gleich aufgebaut.
7. `make_release.py` vor dem Veröffentlichen: „latest“, kein Vorabrelease, beide Update-Dateien, Dateinamen exakt,
   Signaturen gültig (läuft automatisch in `verify_release_dir()` und vor `--publish` als Plan-Prüfung).
8. Nach dem Veröffentlichen: beide `latest/download`-Adressen liefern HTTP 200, die neue Version und eine gültige
   Signatur: `python3 tools/make_release.py --check-published [<Version>]` (liest nur, braucht den Schlüssel).

Öffentlich gibt es Fassungen ab 1.1.0.0; Update-Adressen sind nur `updateinfo-mac.xml`/`updateinfo-win.xml` (und die Beta-Datei).

**Mac-Update-Prüfung Schritt für Schritt** (D3/1 und D3/3):

1. Vorher `defaults export de.mlafx.klimacontrol <Datei>` (Testinstanzen teilen die UserDefaults-Domäne mit der
   installierten App). Die installierte App beendet nur der Nutzer selbst; ein Beenden per `osascript` lehnt der
   Auto-Modus ab.
2. Originales DMG der Vorversion installieren (Programme-Ordner).
3. `python3 tools/update_test_feed.py --dmg <neues DMG> --serve [--key-file <Datei>]` (Optionen im Skriptkopf): lokale,
   echt signierte Update-Datei auf `http://127.0.0.1:<port>/`. Für D3/3 mit `--version <Probe>`, zusätzlich mit
   `--unsigned` (muss abgelehnt werden).
4. Umleitung: Fassungen unter 1.2: `defaults write de.mlafx.klimacontrol SUFeedURL http://127.0.0.1:<port>/updateinfo-mac.xml`.
   Ab 1.2.0.0: App mit `open --env KLIMACONTROL_UPDATE_TEST_FEED=http://127.0.0.1:<port>/updateinfo-mac.xml <App>` starten.
5. `defaults delete de.mlafx.klimacontrol SULastCheckTime`, damit sofort gesucht wird; Suche mit „Nach Updates suchen …“
   (per UI-Scripting auslösbar). Das Hinweisfenster per Fenster-ID fotografieren (`screencapture -l <ID>`).
6. Prüfen: still geladen, Neustart (ab 1.2.0.0 „Jetzt neu starten · Später“), „Neu in …“, Einstellungen erhalten, keine
   neuen Rückfragen.
7. Aufräumen: `defaults delete de.mlafx.klimacontrol SUFeedURL`, ggf. `SUInitialFailedFeedSigningValidationDate` löschen,
   `lastSeenVersion` prüfen, Server stoppen, Testdateien (`~/Library/Caches/Klimacontrol-update-test/`) in den
   Papierkorb, Einstellungen mit `defaults import` zurückspielen.

**D4 – Notbremse:** Release auf „Vorabrelease“ stellen und `gh release edit v<vorige Version> --latest`; die Korrektur
kommt als nächste Fehlerbehebungs-Version (z. B. `1.2.0.1`). `python3 tools/make_release.py --rollback <kaputt> <vorige>`
zeigt die beiden Befehle, mit `--execute` führt es sie nacheinander aus.

### 14.2 Git / GitHub

- Ignoriert (`.gitignore`): Build-Ordner, `dist/`, `releases/`, `_privat/`, `CLAUDE.md`, `.vscode/`, `.DS_Store`, `.agent-lock`.
- Ausführbar sind nur `tools/build_app.sh` und `tools/test.sh` (die Python-Skripte startet man mit `python3`).
  OneDrive setzt synchronisierte Dateien gern auf `rwx` – darum im Repo `git config core.fileMode false` und die
  beiden Skripte ausdrücklich markieren (`git update-index --chmod=+x tools/build_app.sh tools/test.sh`).
- `CLAUDE.md`/`CODEX.md` sind lokale Einstiege für Agenten (verweisen zusätzlich auf `_privat/`) und werden ignoriert;
  öffentlich ist nur diese AGENTS.md.
- **Kein automatischer Bau auf GitHub.** Signiert und notarisiert wird nur am Mac des Autors (`tools/build_app.sh`);
  die Pakete unter „Releases“ lädt er selbst hoch. Vor jedem Hochladen lokal `tools/test.sh` bzw.
  `tools\build_windows.ps1` ausführen.

**Zweige, Releases und Historie (verbindlich):**

- **`main` ist der veröffentlichte Stand.** Auf `main` kommt nur ein Release: erst wenn alles fertig und geprüft ist
  (Tests beider Plattformen grün, Release-Prüfungen bestanden, Pakete gebaut und notarisiert), und im selben Ablauf
  wie Tag und GitHub-Release. Nie Zwischenstände, nie direkte Commits auf `main`.
- Entwickelt wird auf einem Zweig je Version, `entwicklung-<Hauptversion>.<Funktionen>` (z. B. `entwicklung-1.2`).
  Commits dort nach grünen Tests, in sinnvollen Schritten, mit deutscher Nachricht, die die Änderung beschreibt.
- Der Weg nach `main` ist ein **Pull Request mit Merge-Commit** (kein Squash, kein Rebase), damit die Einzelschritte
  sichtbar bleiben. Danach Tag `v<Version>` auf den Merge-Commit und das Release.
- **Die Historie ist öffentlich und wird nicht umgeschrieben:** kein Force-Push, kein Zusammenfassen, kein
  `reset` auf veröffentlichte Commits.
- **Tags sind unveränderlich:** `v<Version>` (Release) und `v<Version>b<n>` (Beta) werden einmal gesetzt und nie
  verschoben oder gelöscht. Veröffentlichte
  Releases und ihre Dateien werden nicht gelöscht oder umbenannt (installierte Fassungen laden von dort).
- Diese Regeln gelten verbindlich als Absprache. Eine technische Erzwingung durch GitHub-Regelsätze („main nur per
  Release-Merge“, „Release-Tags unveränderlich“) ist derzeit nicht eingerichtet (Stand 08.11.2026) und bleibt dem Autor
  überlassen; bis dahin schützt nur die Disziplin. Nichts „schnell“ umgehen.
- Nächste Entwicklung: neuer Zweig `entwicklung-1.3` erst auf Auftrag. `tools/VERSION` bleibt bis zur Freigabe des Autors
  1.2.0.0; ein neuer CHANGELOG-Abschnitt entsteht erst, wenn der Autor die nächste Version festlegt.
- Notfall nach einem fehlerhaften Release: das Release auf „Vorabrelease“ stellen und das vorige mit
  `gh release edit v<vorige Version> --latest` wieder zum neuesten machen; die Korrektur kommt als neue Version.

### 14.3 CHANGELOG-Stil

Der Abschnitt einer Version geht unverändert in die Update-Anzeige (Appcast) und den Release-Text. Darum:

- **Nur was Endnutzer merken:** neue Funktionen, behobene Fehler, geändertes Verhalten. Nicht: Bau, Tests, Skripte,
  Code-Umbau, Angleichung der Plattformen, Begriffswechsel, Protokoll-Interna. Erlaubt ist eine Sammelzeile am Ende („Technischer Unterbau
  überarbeitet und optimiert, zahlreiche kleinere Fehler behoben.“).
- **Eine Zeile je Punkt**, kurzer ganzer Satz oder „Bereich: Aussage“. Etwa 15–20 Punkte je Version; Ähnliches
  zusammenfassen.
- **Sachlich-technisch, konkret:** benennen, was falsch war bzw. was die App jetzt tut („Uhrzeiten wurden in UTC statt
  in Ortszeit angezeigt.“), nicht werben oder beschwichtigen.
- **Ohne Anrede** (weder du noch Sie) – es geht um ein Programm.
- **Nicht nach KI klingen:** keine Gedankenstrich-Einschübe, keine Floskeln („samt“, „wirklich“, „ab sofort“), keine
  Parallelformeln („nichts doppelt, nichts verloren“), keine Fettschrift, keine Erklärsätze zur Begründung.
- Plattformspezifisches mit „Mac:“ bzw. „Windows:“ am Zeilenanfang (die jeweils andere Plattform bekommt die Zeile im
  Appcast nicht). Begriffe nach dem Glossar (13.1).
- `CHANGELOG.en.md` (ab 1.2.0.0) nach denselben Regeln: sachlich, ohne Anrede („Added language selection …“, nicht
  „You can now …“), eine Zeile je Punkt, Zeile für Zeile dieselbe Aussage wie im deutschen Eintrag, Begriffe nach dem
  englischen Glossar.

Beispiel:

```markdown
### Hinzugefügt
- Verlauf: Verbrauch und Kosten je Tag, Woche oder Monat als Balkendiagramm.

### Behoben
- Midea-Konto: Die gespeicherte Anmeldung wird bei Netzwerkfehlern nicht mehr verworfen.
- Ein per WLAN bereits gesendeter Befehl geht nicht zusätzlich über die Cloud raus.
- Windows: Uhrzeiten wurden in UTC statt in Ortszeit angezeigt.

### Geändert
- „Nur Cloud“ setzt ein angemeldetes Midea-Konto voraus.
- Mac: Die Einstellung „Größe“ skaliert auch Knöpfe und Regler.
```

### 14.3a QA-Checkliste für Oberflächen-Releases

Vor dem Bau am fertigen Bündel prüfen (Anlage nur lesen, 5):

- Start mit „Neu in …“ (nach Update oder bei zurückgesetztem `lastSeenVersion`).
- Hauptfenster: kleinste und größte Größe, alle Spaltenkombinationen, Vollbild hinein und heraus, Zoom.
- Themen Standard und Kontrast, je hell und dunkel; alle drei Größen; Umfang Einfach und Alles.
- Alle Einstellungsreiter, Menüleiste, Mini-Fenster.
- Englisch (`-AppleLanguages '(en)'`) und Pseudo-Sprache (`KLIMACONTROL_PSEUDO=1`): nichts abgeschnitten oder unübersetzt.
- Grafikspeicher beim Größenändern und Umschalten der Spalten (`footprint <PID>`), keine Dauerspitzen.
- Vorher UserDefaults sichern (`defaults export`), nachher zurückspielen.

### 14.4 Release Schritt für Schritt

Voraussetzungen: Tests beider Plattformen grün, D3-Prüfungen abgehakt (Ergebnis in der Übergabe), `CHANGELOG.md` und
`CHANGELOG.en.md` vollständig, Freigabe des Autors. Regeln dahinter stehen in 14.1 (D1–D4) und 14.2.

1. Mac-Sperre setzen, Windows-Briefkasten lesen, `git status` sauber, Zweig `entwicklung-<x.y>`.
2. Datum in beide CHANGELOG-Köpfe: `## [<Version>] – JJJJ-MM-TT` (englisch ebenso).
3. `python3 tools/sync_release_notes.py && python3 tools/sync_strings.py --check && tools/test.sh`
4. Commit „Release <Version>: Datum im CHANGELOG“.
5. Mac: `KLIMACONTROL_NOTARY_PROFILE=klimacontrol tools/build_app.sh` (Tests, Notarisierung von ZIP und DMG, Ausgabe in `dist/mac/`).
6. Windows, nach dem OneDrive-Abgleich und Bescheid über den Briefkasten: `powershell -ExecutionPolicy Bypass -File tools\build_windows.ps1 -Zip`
   erzeugt `dist\windows\Klimacontrol-Windows-<Version>-Setup.exe`; Windows meldet die SHA-256.
7. Mac: `shasum -a 256 dist/windows/Klimacontrol-Windows-<Version>-Setup.exe` gegen die Meldung prüfen; `git status` sauber.
8. `python3 tools/make_release.py` erzeugt `releases/v<Version>/`; `RELEASE_NOTES.md` und `updateinfo-*.xml` ansehen.

Ab hier nur auf ausdrückliches Kommando des Autors (veröffentlicht):

9. `git push -u origin entwicklung-<x.y>`
10. `gh pr create --repo mlafx/Klimacontrol --base main --head entwicklung-<x.y> --title "Klimacontrol <Version>"`, dann
    `gh pr merge <Nr> --repo mlafx/Klimacontrol --merge` (Merge-Commit, kein Squash, kein Rebase; ohne KI-Hinweis).
11. `git fetch origin && git tag -a v<Version> -m "Klimacontrol <Version>" origin/main && git push origin v<Version>`
    (Tag auf den Merge-Commit; `gh release create` nimmt den vorhandenen Tag).
12. `python3 tools/make_release.py --publish` baut den Ordner neu (der alte wird zu `…alt-<Zeit>`), legt das Release als „latest“
    an (ohne Vorabrelease „beta“ und ohne Beta-Datei). `make_release.py` fragt den Schlüsselbund je Lauf, und `--publish`
    baut den Ordner neu: Der Schlüsselbund-Dialog erscheint erneut (der Autor bestätigt ihn).
13. `python3 tools/make_release.py --check-published` (D3/8).
14. Abschlusstest mit installierten Vorversionen auf Mac und Windows: das echte Update über `latest` kommt an (D3/1, D3/2);
    Mac-Sperre frei, `erledigt` in den Briefkasten.

Das Windows-Setup baut der Windows-Agent auf Anfrage über den Briefkasten (Schritt 6); die SHA-256 der Datei auf dem Mac
immer gegen seine Meldung vergleichen (Schritt 7), bevor `make_release.py` läuft.

Notbremse: `python3 tools/make_release.py --rollback v<Version> v<vorige>` zeigt die zwei `gh release edit`-Befehle, mit
`--execute` werden sie ausgeführt (D4). Die Korrektur kommt als nächste Fehlerbehebungs-Version; nichts löschen, keine Tags verschieben.

Beta (nur Mac): wie oben mit `tools/build_app.sh --beta <n>` und `make_release.py --beta <n>`; Tag `v<Version>b<n>`, kein Pull Request
nach `main`, das Vorabrelease zeigt auf den Entwicklungszweig; die erste Beta legt das Release „beta“ an (siehe 14.1).

---

## 15. Rezepte für typische Aufgaben

### 15.1 Neue Einstellung (beide Plattformen)

1. Schlüssel in `SettingsKey` (oder Feld in `Appearance`, wenn es ums Aussehen geht – dann Decoding, `clamped`,
   Themen-Verhalten und `AppearanceTests` mitpflegen).
2. Eigenschaft in `ACController` mit Klemmen/Prüfen im Setter, Protokollzeile, ggf. `restartPolling()`.
3. Test im Kern (Speichern, Laden, Grenzwerte).
4. Bridge: Feld im Schnappschuss + Befehl in `kc_command` (Pflichtparameter!), `bridge-muster.json` ergänzen;
   bei Bedeutungsänderung `bridgeAPIVersion` erhöhen.
5. Mac: Steuerelement im passenden Reiter; Windows: dasselbe im selben Reiter mit demselben Text.
6. CHANGELOG (Abschnitt der laufenden Version), beide Builds.

### 15.2 Neuer Befehl an die Anlage

1. Rahmen in `Commands.swift` (`Frame`), Antwort in `Responses.swift`; Bytes gegen msmart-ng oder einen echten
   Mitschnitt (Debug-Protokoll) prüfen.
2. Methode in `PortaSplitDevice` mit Verifikation und Wiederholung wie die vorhandenen Setter, im `ACDevice`-
   Protokoll und im `FakeDevice` nachbilden.
3. Tests mit Rahmen-Bytes (`MideaKitTests`) und Verhalten (`ControllerTests`).
4. Erst danach Kern-Aktion, Bridge, Oberflächen. Live-Test an der Anlage nur mit ausdrücklichem Auftrag.

### 15.3 Neuer Diagnosewert

Gruppe/Byte in `Diagnostics` und `Response` lesen, in `HistorySample`/CSV-Kopf nur, wenn er in den Verlauf soll
(neue Spalte = Migration in `HistoryDB` + Export/Import + Anhang B), Anzeige in `PanelsDiagnostics.swift` und
`DiagnosticsPanel.xaml`, Tabelle in Anhang C ergänzen.

### 15.4 Neues Thema

`Appearance.Theme` erweitern, `preset` füllen, Mac `ThemeStyle` und Windows `Theme.cs` umsetzen, Kontrast prüfen,
`AppearanceTests` und `ThemeTests` ergänzen.

### 15.5 Fehler „Anlage belegt / antwortet nicht“ untersuchen

1. Ausführliches Protokoll an (Einstellungen → Protokoll; groß, rotiert nach Stunden), Rahmen in hex ansehen.
2. Andere Verbindungen ausschließen (Midea-App, zweiter Rechner, Diagnose-Takt < 8 s).
3. Wegwahl-Sperren im Protokoll („Verbindung über …“, „in N min“) prüfen.
4. Erst dann Code ändern – und nie die Zeiten aus 6.3 „ausprobieren“.

---

## 16. Bekannte Grenzen und offene Fragen

- Nur eine Verbindung gleichzeitig (6.3). Gerätetimer per LAN nicht möglich → App-Timer (laufen nur bei offener App
  und wachem Rechner).
- „Außengerät leise“ wirkt nur beim Kühlen/Heizen.
- Ohne Midea-Konto kann die App Token/Schlüssel nicht selbst holen.
- Nicht eingebaut: Schlafmodus, Kindersicherung (0x0051), „Leise“-Stufen innen/beide (0x00CD Fähigkeit 3).
- Windows, helles Glas im Thema Standard: graue Texte und die große Zahl haben auf dem Glas wenig Kontrast (mit
  „Matt“ deutlich mehr). Bewusst so belassen, das Aussehen des Standard-Themas bleibt; nicht als Fehler verfolgen.
- „Leistung begrenzen“ bleibt bewusst bei beiden Stufen (75 und 50 %); maßgeblich ist der zurückgemeldete Wert (6.5).
- Wie die PortaSplit ein falsches Token im Handshake beantwortet (Fehlerpaket 0xF oder Schweigen), ist nicht
  gemessen. Heute wird 0xF als Protokollfehler gewertet, nicht als Ablehnung; ändern erst nach einem Mitschnitt.
- Unbekannte Werte der Anlage: Anhang D.

- Das Windows-Hauptfenster ist bereits in der Größe veränderbar; die Regeln des Mac-Fensters (9.1, `MainWindowLayout`)
  werden für 1.3 angeglichen.
- Mac: Der Schalter „Vorabversionen (Beta) erhalten“ meldet bis zur ersten Beta „Suche hat nicht geklappt“, weil es die
  Beta-Datei (und das Release „beta“) noch nicht gibt. Bekannt, kein Fehler im Release.
- Für 1.3 vorgemerkt (QA 1.2.0.0): leere Fläche unter dem Außentemperatur-Graphen im Vollbild; die englische Verbrauchsachse
  schneidet Tagesnamen ab; das Windows-Fenster an die Mac-Regeln angleichen; Verhalten des Mac-Beta-Schalters ohne Beta-Kanal.
- Windows: Die Einstellungen in `%LOCALAPPDATA%\Klimacontrol.exe.plist` liest swift-corelibs-foundation; ist die Datei
  kaputt oder von einem anderen Werkzeug umgeschrieben, gelten still alle Standardwerte (seit 1.0 so). Die Datei nur als
  Text ändern, nie mit einer XML-Bibliothek neu schreiben. Robusteres Lesen ist für später vorgemerkt.

## 17. Lizenz und Marken

Klimacontrol steht unter der MIT-Lizenz (`LICENSE`). Das Protokoll ist nachgebaut nach msmart-ng,
midea-beautiful-air und midea_ac_lan (alle MIT); dazu swift-crypto/swift-asn1 (Apache 2.0), SQLite (gemeinfrei),
Sparkle (MIT u. a., Mac) und WinSparkle (MIT, Windows).
Vermerke stehen in `docs/THIRD_PARTY_NOTICES.md` und in der App unter „Lizenzen“. Midea, MSmartHome, NetHome Plus und
PortaSplit sind Marken ihrer Inhaber; Klimacontrol ist kein Produkt von Midea – diesen Hinweis nicht entfernen.

---

## Anhang A: Dateien der App

Ablage: Mac `~/Library/Application Support/Klimacontrol/`, Windows `%LOCALAPPDATA%\Klimacontrol\`.
Einstellungen liegen getrennt davon: Mac in den UserDefaults (`de.mlafx.klimacontrol`), Windows in
`%LOCALAPPDATA%\Klimacontrol.exe.plist` (7.7).

| Datei | Inhalt |
|---|---|
| `device.json` (0600) | Name, IP, Port, Geräte-ID, Token (128 Hex), Schlüssel (64 Hex), optional `bleSerial`; bei Cloud-Einrichtung nur Name und Geräte-ID |
| `szenen.json` | Szenen |
| `verlauf.sqlite` | Verlauf (7.6) |
| `verlauf.csv` | nur mit „Zusätzlich als CSV schreiben“, alle 30 s, `;`-getrennt |
| `klimacontrol.log` (+ `.1`, `.2`) | Protokoll, rotiert bei 5 MB; Passwort/Token/Schlüssel/Sitzung geschwärzt; Debug (Standard aus) ergänzt Rahmen in hex, Suche und Cloud-Anfragen |

**Sicherung** („Zugangsdaten sichern …“, Datei 0600): JSON mit `devices` (`ip`, `port`, `deviceId`, `token`, `key`)
und optional `scenes`. „Aus Zwischenablage einfügen“ erkennt denselben JSON-Block. Beim Einlesen wird an der Anlage
geprüft (`verified` true/false/nil); Sicherungen einer anderen Anlage nur mit `allowOtherDevice`.

**Neu einrichten** legt `device.json` unverändert (mit Token und Schlüssel) in den Papierkorb bzw. benennt sie unter
Windows um – der Bestätigungsdialog sagt das offen. Darum vorher sichern.

## Anhang B: CSV-Spalten des Verlaufs

`;`-getrennt, eine Zeile je Messpunkt, leeres Feld = unbekannt.

| Spalte | Einheit / Werte |
|---|---|
| `zeit` | ISO 8601 mit Zone (technisch) bzw. `JJJJ-MM-TT HH:MM:SS` Ortszeit (lesbar) |
| `ein`, `eco`, `turbo`, `aussen_leise`, `kondensatpumpe`, `abtauen` | 1 = an, 0 = aus |
| `modus` | Kühlen, Heizen, Trocknen, Lüften, Auto |
| `soll_c`, `innen_c`, `aussen_c`, `t1`–`t4`, `tp` | °C |
| `luefter` | 1–100 % bzw. Stufencode (102 = Auto) |
| `leistung_w`, `verdichter_w` | W |
| `gesamt_kwh` | Zählerstand in kWh |
| `verdichter_hz`, `verdichter_soll_hz` | Hz |
| `strom_a`, `spannung_v` | A, V |
| `eev` | Ventilöffnung (Rohwert) |
| `luefter_innen_upm`, `luefter_aussen_upm` | U/min |
| `zaehler_roh` | Zählerstand als Rohwert (Schritte à 0,01 kWh) |

**Lesbare Form:** Die Kopfzeile folgt der Sprache der Oberfläche (deutsch: `Zeit (Ortszeit);Eingeschaltet (1/0);Modus;…`,
englisch: `Time (local time);Power on (1/0);Mode;Target (°C);…;Meter raw`; wörtlich in `HistoryTests` bzw.
`HistoryLanguageTests`). Modus-Namen und Dezimalzeichen richten sich nach Sprache bzw. Format; der Import liest beide
Sprachen. Die technische Form und die Datenbank bleiben deutsch.

## Anhang C: Herkunft der Messwerte

| Wert | Quelle |
|---|---|
| Grundzustand | Antwort 0xC0 auf Abfrage 0x41 |
| Außengerät leise / Selbstreinigung / iECO / Signalton / Leistung begrenzen | Eigenschaften 0x00CD / 0x0039 / 0x00E3 / 0x022C / 0x0048 |
| Leistung W | Gruppe 4, Byte 16–18, binär / 10 |
| Zählerstand kWh | Gruppe 4, Byte 4–7, binär, 0,01 kWh je Schritt |
| Verdichter Hz/Soll, Strom, Spannung, T1–T4, TP | Gruppe 1 |
| Innenlüfter, Kondensatpumpe | Gruppe 2 |
| EEV-Öffnung | Gruppe 3, Byte 11 (nicht in msmart-ng; bewegt sich mit dem Verdichter) |
| Außenlüfter, Abtauen | Gruppe 5 |
| Verdichterleistung | Gruppe 7 |
| Gerätekennung | Eigenschaft 0x00AB (ASCII Modell-/Firmwarecode) |

Fähigkeiten (0xB5) der PortaSplit: Modi Kühlen/Heizen/Trocknen/Auto (+ Lüften), Schwenken nur vertikal, Ionisierer,
Filtererinnerung, Turbo bei Kühlen und Heizen, Lüfter stufenlos, 16–30 °C ohne Nachkommastellen, Anzeige,
Leistungsbegrenzung (2 Stufen), Signalton, Verbrauchsmessung binär, Selbstreinigung, iECO, Frostschutz (8 °C, nur
Heizen), Kindersicherung, „Leise“ (Stufe 3). Keine Feuchte, keine Zusatzheizung, kein horizontales Schwenken.

## Anhang D: Unbekannte Werte der Anlage

| Quelle | Daten | Vermutung |
|---|---|---|
| Eigenschaft 0x0051 | `00 20 3c 00 00` | Kindersicherung aus, Temperaturgrenzen 16–30 °C |
| Eigenschaft 0x00CD | Fähigkeit `03` | „Leise“ auch nur innen oder beide |
| Eigenschaft 0x0030 | `00 1e 00 00 00 07` | nicht als Fähigkeit gemeldet, ändert sich |
| Eigenschaft 0x001E | `00 06 00 00` | unbekannt |
| Eigenschaft 0x007E | 46 Byte | kompakte Kopie des Betriebszustands |
| Eigenschaft 0x00E0 | `01 34 08 34 08 08 07 90 01 5e 01 60 09 00` | enthält 400, 350, 2400 – evtl. Grenzwerte |
| Eigenschaft 0x00E1 / 0x00E2 | `01` / 40 Byte | unbekannt |
| Eigenschaft 0x00F0 | 52 Byte | Sammelblock (Gruppe 4, Spannung, Gruppe 6); ersetzt nur Gruppe 4, kein Zeitgewinn – nicht genutzt |
| Gruppe 0, Byte 17 | `07` → `1e` | Zähler/Status |
| Gruppe 3, Byte 9/12–14 | konstant | evtl. Modell/Firmware |
| Gruppe 5, Byte 5 | steigt langsam | evtl. Temperatur |
| Gruppe 6, Byte 4–9 | Byte 8 zählt hoch | evtl. Betriebsstunden |
| Gruppe 12, Byte 4–6 | `02 00 0f` | evtl. Firmware 2.0.15 |

Neue Erkenntnisse hier nachtragen (mit Messgrundlage), nicht in Code-Kommentaren.
