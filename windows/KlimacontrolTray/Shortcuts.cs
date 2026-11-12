using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;

namespace KlimacontrolTray;

/// Was ein Tastenkürzel auslöst.
enum ShortcutCommand { None, Power, Warmer, Colder, Refresh, Settings, ToggleCharts, ToggleDiag }

/// Tastenkürzel für Hauptfenster und Fenster am Infobereich: Strg+P Ein/Aus, Strg+↑/↓ wärmer/kälter, Strg+R/F5
/// aktualisieren, Strg+, Einstellungen, im Hauptfenster Strg+G Verlauf und Strg+D Diagnose. Nackte Pfeiltasten
/// bleiben wie am Mac frei: Sie gehören Scrollbereichen, Reglern und der Tastaturnavigation.
static class Shortcuts
{
    /// Reine Entscheidung. `targetAdjustable`: Soll verstellbar (an, nicht Lüften). `panels`: Verlauf/Diagnose lassen sich umschalten (Hauptfenster mit Werten).
    public static ShortcutCommand Resolve(Key key, ModifierKeys mods, bool targetAdjustable, bool typing, bool panels)
    {
        if (key == Key.F5 && mods == ModifierKeys.None) return ShortcutCommand.Refresh;
        if (mods != ModifierKeys.Control) return ShortcutCommand.None;
        return key switch
        {
            Key.P => ShortcutCommand.Power,
            Key.Up when targetAdjustable && !typing => ShortcutCommand.Warmer,
            Key.Down when targetAdjustable && !typing => ShortcutCommand.Colder,
            Key.R => ShortcutCommand.Refresh,
            Key.OemComma => ShortcutCommand.Settings,
            Key.G when panels => ShortcutCommand.ToggleCharts,
            Key.D when panels => ShortcutCommand.ToggleDiag,
            _ => ShortcutCommand.None,
        };
    }

    /// Hängt die Kürzel an PreviewKeyDown, damit fokussierte Knöpfe sie nicht vorher schlucken. `leaving` läuft,
    /// bevor die Einstellungen aufgehen.
    public static void Attach(Window window, ControlPanel controls, Action? toggleCharts = null, Action? toggleDiag = null,
                              Action? leaving = null)
    {
        window.PreviewKeyDown += (_, e) =>
        {
            if (e.Handled) return;
            var key = e.Key == Key.System ? e.SystemKey : e.Key;
            var focused = Keyboard.FocusedElement;
            var cmd = Resolve(key, Keyboard.Modifiers, ControlPanel.TargetAdjustable(Core.Shared.Snap),
                              controls.IsTyping || IsTextInput(focused),
                              toggleCharts != null && toggleDiag != null && Core.Shared.Snap.State != null);
            if (cmd == ShortcutCommand.None) return;
            var app = (App)Application.Current;
            switch (cmd)
            {
                case ShortcutCommand.Power: app.TogglePower(); break;
                case ShortcutCommand.Warmer: Core.Shared.Send(Cmd.NudgeTemp, ("delta", 1.0)); break;
                case ShortcutCommand.Colder: Core.Shared.Send(Cmd.NudgeTemp, ("delta", -1.0)); break;
                case ShortcutCommand.Refresh: Refresh(); break;
                case ShortcutCommand.Settings: leaving?.Invoke(); app.ShowSettings(SettingsTab.General); break;
                case ShortcutCommand.ToggleCharts: toggleCharts?.Invoke(); break;
                case ShortcutCommand.ToggleDiag: toggleDiag?.Invoke(); break;
            }
            e.Handled = true;
        };
    }

    /// Hebt im Kern die Sperren der Wegwahl auf und probiert alle Wege neu; nur mit eingerichteter Anlage.
    public static void Refresh()
    {
        if (Core.Shared.Snap.Configured) Core.Shared.Send(Cmd.Refresh);
    }

    static bool IsTextInput(IInputElement? focused) => focused is TextBoxBase or PasswordBox;
}
