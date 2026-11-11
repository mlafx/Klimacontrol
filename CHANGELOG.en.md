# Changelog

Newest version first; sections "Added", "Changed", "Fixed", "Removed"; English, from the user's point of view.
Versions have four parts, major.features.fixes.build. Earlier versions are available in German only.

## [1.3.0.0] – in progress

### Added
- History: Power, temperature and outdoor temperature share one card with a common time axis.
- History: A colored band below the power shows when the air conditioner ran in which mode.
- Consumption: Value above each bar and a dashed line for the average of completed periods.
- Appearance: Setting “Show outdoor temperature in the temperature chart”.
- The target temperature scale shows the room temperature as a marker.
- Windows: A damaged settings file is set aside and reported at startup instead of being silently replaced with default values.

### Changed
- Main window: Mode and fan, as well as scenes and timers, each share one card.
- The power button is labeled “On” or “Off”.
- History: Average, peak, consumption and cost appear as one line below the power instead of four tiles.
- History: Target dashed in the color of the mode, outdoor temperature dotted gray and smoothed.
- History: Power and temperatures use the same axes and grid lines on Mac and Windows.
- Windows: The main window follows the same rules for columns and size as on the Mac; tabs and stacked columns are gone.
- Windows: In Fan mode, the target temperature and its scale are hidden.

### Fixed
- History: Labels under the consumption bars and the last time under the charts were cut off.
- Mac: In full screen, an empty area remained below the outdoor temperature chart.
- If the history cannot be saved, a notice appears instead of “Not enough data yet”.
- Mac: With the beta channel turned on, every check failed while no pre-release existed, and stable updates were not installed.
- Mac: The menu bar window stayed too tall after turning off the air conditioner and showed its content at the bottom without rounded corners.
- Windows: Release notes in the update window were hard to read in dark mode.
- English interface: Notices about a switched-off air conditioner, the Local Network permission and the time limit appeared partly in German or only as “not reachable”.
- Setup with the Midea account: A busy or unresponsive air conditioner was reported as rejecting the token.
- Restore backup: One unreadable scene silently discarded all scenes of the backup.
- Find address again: An invalid address found by the search ended without any feedback.
- Mini window: With the room temperature shown large but not reported, “–” appeared instead of the target temperature.
- Mac: ⌘↑ and ⌘↓ changed the target temperature in Fan mode.
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
