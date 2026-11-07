using System;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace KlimacontrolTray;

/// Randlose Fenster mit `AllowsTransparency`: Wird ihr Hintergrund ganz durchsichtig, nimmt `Keep` die Fläche `Bg` –
/// sonst wäre das Fenster unsichtbar und Klicks gingen hindurch.
static class Surface
{
    static readonly DependencyPropertyDescriptor BackgroundDescriptor =
        DependencyPropertyDescriptor.FromProperty(Control.BackgroundProperty, typeof(Window));

    public static void Keep(Window w)
    {
        var fixing = false;
        void Check()
        {
            if (fixing || !IsInvisible(w.Background)) return;
            fixing = true;
            try { w.SetResourceReference(Control.BackgroundProperty, "Bg"); }
            finally { fixing = false; }
        }
        EventHandler changed = (_, _) => Check();
        BackgroundDescriptor.AddValueChanged(w, changed);
        // Der Beschreiber hält das Fenster sonst fest.
        w.Closed += (_, _) => BackgroundDescriptor.RemoveValueChanged(w, changed);
        Check();
    }

    static bool IsInvisible(Brush? b) => b switch
    {
        null => true,
        SolidColorBrush s => s.Color.A == 0 || s.Opacity <= 0,
        _ => b.Opacity <= 0,
    };
}
