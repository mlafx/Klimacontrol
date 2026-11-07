# Sicherheit

## Lücken melden

Bitte meldet Sicherheitslücken nicht als öffentliches Issue, sondern privat über **Security → Report a
vulnerability** hier im Repository. Ich melde mich dort und sage Bescheid, sobald es eine Lösung gibt.

Unterstützt wird nur die jeweils neueste Version.

## Wie Klimacontrol abgesichert ist

- **Updates** kommen nur von der Release-Seite dieses Repositorys und sind mit EdDSA (Ed25519) signiert. Mac
  (Sparkle) und Windows (WinSparkle) prüfen die Signatur gegen den öffentlichen Schlüssel in
  [`tools/UPDATE_PUBLIC_KEY`](tools/UPDATE_PUBLIC_KEY), bevor sie etwas installieren.
- **Mac:** Die App ist mit einer Developer ID signiert und von Apple notarisiert.
- **Windows:** Das Setup ist nicht Authenticode-signiert, Windows zeigt beim ersten Start deshalb einen
  SmartScreen-Hinweis. Die Prüfsummen aller Dateien stehen in `SHA256SUMS.txt` am jeweiligen Release.
- **Zugangsdaten** der Anlage (Token und Schlüssel) und das Midea-Passwort bleiben auf dem eigenen Rechner: in einer
  nur für den Benutzer lesbaren Datei bzw. im Schlüsselbund oder in der Windows-Anmeldeinformationsverwaltung. Im
  Protokoll werden sie geschwärzt.
- Das LAN-Protokoll der Anlage (AES mit festen Schlüsseln, wie Midea es vorgibt) lässt sich von der App aus nicht
  stärker absichern. Die Anlage gehört deshalb in ein vertrauenswürdiges WLAN.
