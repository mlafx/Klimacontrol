# Changelog

Neueste Version oben; Abschnitte „Hinzugefügt“, „Geändert“, „Behoben“, „Entfernt“; Deutsch, aus Sicht des Nutzers.
Versionen haben vier Stellen, Hauptversion.Funktionen.Fehlerbehebung.Bau: neues Paket ohne Änderung für Nutzer →
`1.0.0.1`, Fehlerbehebung → `1.0.1.0`, Neues → `1.1.0.0`, Änderungen, die Einrichtung oder Daten unbrauchbar machen →
`2.0.0.0`.

## [1.2.0.0] – in Arbeit

### Hinzugefügt
- Englische Oberfläche. Bei deutscher Systemsprache bleibt die App deutsch, bei jeder anderen erscheint sie auf Englisch.
- Einstellungen → Allgemein: Auswahl der Sprache (Systemsprache, Deutsch, English). Die Änderung wirkt nach einem Neustart der App.
- Mac: Die Sprache lässt sich auch unter Systemeinstellungen → Allgemein → Sprache & Region → Apps festlegen.
- Einstellungen → Allgemein: Währung des Strompreises frei wählbar, bis zu drei Zeichen, Standard €.
- Mac: Einstellungen → Allgemein → Updates: Vorabversionen (Beta) können bezogen werden, standardmäßig aus.
- Windows: Setup auf Deutsch und Englisch, passend zur Anzeigesprache von Windows.
- Signalton lässt sich im Hauptfenster unter „Weitere Funktionen“ schalten.

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
