# Sicherheit

## Lücken melden

Bitte meldet Sicherheitslücken nicht mit Einzelheiten in einem öffentlichen Issue. Der Weg ist **Security → Report a
vulnerability** hier im Repository. Ist diese Schaltfläche nicht vorhanden, bitte ein Issue ohne Einzelheiten anlegen
(nur „Sicherheitslücke, bitte Kontakt“); die Einzelheiten klären wir dann privat. Unterstützt wird nur die jeweils
neueste Version. Ich melde mich dort und sage Bescheid, sobald es eine Lösung gibt.

## Wie Klimacontrol abgesichert ist

- **Updates** kommen nur von der Release-Seite dieses Repositorys und sind mit EdDSA (Ed25519) signiert. Mac
  (Sparkle) und Windows (WinSparkle) prüfen die Signatur gegen den öffentlichen Schlüssel in
  [`tools/UPDATE_PUBLIC_KEY`](tools/UPDATE_PUBLIC_KEY), bevor sie etwas installieren.
- **Mac:** Die App ist mit einer Developer ID signiert und von Apple notarisiert.
- **Windows:** Beim ersten Start des aus dem Browser geladenen Setups zeigt Windows einen
  Sicherheitshinweis (SmartScreen oder „Unbekannter Herausgeber“); Updates über die App zeigen ihn nicht. Die Prüfsummen aller Dateien stehen in `SHA256SUMS.txt` am jeweiligen Release.
- **Zugangsdaten** der Anlage (Token und Schlüssel) und das Midea-Passwort bleiben auf dem eigenen Rechner: in einer
  nur für den Benutzer lesbaren Datei bzw. im Schlüsselbund oder in der Windows-Anmeldeinformationsverwaltung. Im
  Protokoll werden sie geschwärzt.
- Das LAN-Protokoll der Anlage (AES mit festen Schlüsseln, wie Midea es vorgibt) lässt sich von der App aus nicht
  stärker absichern. Die Anlage gehört deshalb in ein vertrauenswürdiges WLAN.

---

# Security (English)

## Reporting a vulnerability

Please do not post details of a security issue in a public issue. Use **Security → Report a vulnerability** in this
repository. If that button is not available, open an issue without details (only "security issue, please get in
touch"); details are then exchanged privately. Only the latest version is supported.

## How Klimacontrol is protected

- **Updates** come only from the release page of this repository and are signed with EdDSA (Ed25519). Mac (Sparkle)
  and Windows (WinSparkle) verify the signature against the public key in
  [`tools/UPDATE_PUBLIC_KEY`](tools/UPDATE_PUBLIC_KEY) before installing anything.
- **Mac:** The app is signed with a Developer ID and notarized by Apple.
- **Windows:** When the setup is downloaded in a browser, Windows shows a security notice on first launch
  (SmartScreen or “Unknown publisher”); updates through the app do not show it. The
  checksums of all files are in `SHA256SUMS.txt` on each release.
- **Credentials** of the air conditioner (token and key) and the Midea password stay on your own computer: in a file
  readable only by the user, or in the Keychain or the Windows Credential Manager. They are redacted in the log.
- The air conditioner's LAN protocol (AES with fixed keys, as specified by Midea) cannot be made stronger from within
  the app. The air conditioner therefore belongs in a trusted Wi-Fi network.
