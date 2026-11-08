# Changelog

Newest version first; sections "Added", "Changed", "Fixed", "Removed"; English, from the user's point of view.
Versions have four parts, major.features.fixes.build. Earlier versions are available in German only.

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
