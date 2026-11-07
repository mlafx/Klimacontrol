using System;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;

namespace KlimacontrolTray;

/// Schriftgrößen eines Teilbaums nach „Größe“ (`Theme.SizeFactor`), ohne die Oberfläche als Ganzes zu skalieren.
/// Die Grundgröße wird beim ersten Besuch gemerkt, geerbte Größen bleiben unberührt: Elemente darum mit der Grundgröße
/// anlegen und danach `Apply` rufen; selbst gesetzte Größen mit `Own` ausnehmen.
static class SizeScale
{
    sealed class Entry
    {
        public double Base;
        public bool Skip;
    }

    static readonly ConditionalWeakTable<DependencyObject, Entry> entries = new();

    /// Dieses Element setzt seine Schriftgröße selbst – `Apply` lässt es aus.
    public static void Own(DependencyObject d) => entries.AddOrUpdate(d, new Entry { Skip = true });

    /// Schriftgrößen unter `root` auf Grundgröße × `factor` (auf halbe Pixel gerundet).
    public static void Apply(DependencyObject root, double factor)
    {
        if (root is TextBlock or Control) Scale(root, factor);
        foreach (var child in LogicalTreeHelper.GetChildren(root))
            if (child is DependencyObject d) Apply(d, factor);
    }

    static void Scale(DependencyObject d, double factor)
    {
        var p = TextElement.FontSizeProperty;
        if (!entries.TryGetValue(d, out var e))
        {
            var source = DependencyPropertyHelper.GetValueSource(d, p).BaseValueSource;
            e = source is BaseValueSource.Local or BaseValueSource.Style
                ? new Entry { Base = (double)d.GetValue(p) }
                : new Entry { Skip = true };
            entries.AddOrUpdate(d, e);
        }
        if (e.Skip) return;
        var size = Math.Round(e.Base * factor * 2) / 2;
        if ((double)d.GetValue(p) != size) d.SetValue(p, size);
    }
}
