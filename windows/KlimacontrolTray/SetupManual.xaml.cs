using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace KlimacontrolTray;

/// Weg „Zugangsdaten eingeben“ ohne Midea-Konto. Die Eingaben gehören dem Kern (`Setup.Manual`); jedes geänderte
/// Feld geht einzeln mit `manualSet` hin. Token und Schlüssel nie protokollieren.
public partial class SetupManual : UserControl
{
    static Core Core => Core.Shared;

    /// Ein Eingabefeld und sein Gegenstück im Kern. `Pending`: getippt, aber der Schnappschuss zeigt den Wert noch
    /// nicht – solange bleibt das Feld, wie es ist (sonst spränge der Cursor bzw. ein Zeichen ginge verloren).
    sealed class Field(TextBox box, TextBlock hint, string key, Func<ManualInfo, string> get)
    {
        public readonly TextBox Box = box;
        public readonly TextBlock Hint = hint;
        public readonly string Key = key;
        public readonly Func<ManualInfo, string> Get = get;
        public bool Pending;
        public string Sent = "";
        /// Abschnitt 1 (Anlage) oder 2 (Token und Schlüssel) – für Fehler beim Senden.
        public bool InSearch => Key is "ip" or "port" or "deviceId";
    }

    readonly Field[] fields;
    readonly TextBlock scanLabel, subnetLabel;
    readonly FoundCards found;
    /// Programmatisches Setzen der Felder (kein `manualSet` zurück an den Kern).
    bool syncing;
    /// Fehler unter der Anlagen-Auswahl (Suche) oder unter den Zugangsdaten (Prüfen/Verbinden/Einfügen).
    bool errorAtSearch;
    /// Sofortige Ablehnung eines Befehls durch den Kern (Rückgabe von Send) – gilt wie `Setup.Error`.
    string? localError;
    /// Zustand der Zähler-Symbole ("Ok", "Sub", "Warn"; nur bei Wechsel neu anlegen).
    string? tokenMark, keyMark;

    public SetupManual()
    {
        InitializeComponent();
        fields = new[]
        {
            new Field(IpBox, IpHint, "ip", m => m.Ip),
            new Field(PortBox, PortHint, "port", m => m.Port),
            new Field(IdBox, IdHint, "deviceId", m => m.DeviceId),
            new Field(TokenBox, TokenHint, "token", m => m.Token),
            new Field(KeyBox, KeyHint, "key", m => m.Key),
        };
        SetupUi.SetupSearch(ScanButton, out scanLabel, SubnetButton, out subnetLabel);
        PasteButton.Content = SetupUi.Labeled(SetupIcons.Clipboard, out _, "Aus Zwischenablage einfügen");
        var ok = Icons.Make(Icons.Check, 12, null, 1.6);
        ok.SetResourceReference(Shape.StrokeProperty, "Ok");
        CheckOkIcon.Content = ok;
        found = new FoundCards(FoundList, true, Use);
        // Enter: verbinden. Knöpfe und Links behandeln ihr Enter selbst.
        KeyDown += (_, e) =>
        {
            if (e.Handled || e.Key != Key.Enter) return;
            e.Handled = true;
            Connect();
        };
    }

    /// Weg betreten: Meldungen weg, Felder beim nächsten Render ganz aus dem Kern übernehmen.
    public void Enter()
    {
        foreach (var f in fields) f.Pending = false;
        localError = null;
        errorAtSearch = false;
        PastedNote.Visibility = Visibility.Collapsed;
    }

    /// Fenster schließt: Token und Schlüssel nicht in den Feldern stehen lassen (der Kern behält sie).
    public void Detach()
    {
        syncing = true;
        foreach (var f in fields)
        {
            f.Box.Clear();
            f.Pending = false;
        }
        syncing = false;
    }

    /// Cursor ins erste leere Feld (sonst Adresse) – damit Tastatur, Enter und Esc im Ablauf bleiben.
    public void FocusFirst()
    {
        var empty = fields.FirstOrDefault(f => f.Key != "port" && f.Box.Text.Length == 0);
        (empty?.Box ?? IpBox).Focus();
    }

    // MARK: Darstellen

    public void Render()
    {
        var s = Core.Snap.Setup;
        // Außerhalb des Wegs „manual“ ist `Setup.Manual` leer – nichts davon in die Felder übernehmen.
        if (s.Path != "manual") return;
        var m = s.Manual;

        SetupUi.RenderSearch(s, ScanButton, scanLabel, SubnetButton, subnetLabel);
        found.Render(s);
        SyncFields(m);

        // Hinweise an Adresse/Port und Anlagen-ID erst, wenn dort etwas steht.
        Note(IpNote, (m.Ip.Length > 0 ? Problem(m, "ip") : null) ?? (m.Port.Length > 0 ? Problem(m, "port") : null));
        Note(IdNote, m.DeviceId.Length > 0 ? Problem(m, "deviceId") : null);
        // Längen und Platzhalter der Felder gibt der Kern vor.
        var cr = Core.Snap.Options.Credentials;
        SetText(IpHint, cr.AddressPlaceholder);
        SetText(PortHint, cr.DefaultPort > 0 ? cr.DefaultPort.ToString(System.Globalization.CultureInfo.InvariantCulture) : "");
        SetText(TokenHint, cr.TokenPrompt);
        SetText(KeyHint, cr.KeyPrompt);
        Count(TokenNote, TokenMark, ref tokenMark, m.TokenCount, cr.TokenLength, CodeProblem(m, "token", m.Token, m.TokenCount, cr.TokenLength));
        Count(KeyNote, KeyMark, ref keyMark, m.KeyCount, cr.KeyLength, CodeProblem(m, "key", m.Key, m.KeyCount, cr.KeyLength));

        var can = m.Complete && !s.Busy;
        CheckButton.IsEnabled = can;
        ConnectButton.IsEnabled = can;
        ConnectButton.Content = s.Busy ? "Verbinde …" : "Verbinden";
        CheckOk.Visibility = s.ManualCheckOK == true ? Visibility.Visible : Visibility.Collapsed;

        RenderMessages(s);
    }

    void RenderMessages(SetupInfo s)
    {
        var error = localError ?? s.Error;
        if (error != null && errorAtSearch) SetupUi.ShowMessage(Msg1, MsgText1, MsgIcon1, error, false);
        else Msg1.Visibility = Visibility.Collapsed;
        if (error != null && !errorAtSearch) SetupUi.ShowMessage(Msg2, MsgText2, MsgIcon2, error, false);
        else Msg2.Visibility = Visibility.Collapsed;
        // Netzwerkhilfe nur unter Meldungen des Kerns, nicht bei sofortigen Ablehnungen.
        SetupUi.RenderHelp(Help1, s, localError == null && errorAtSearch);
        SetupUi.RenderHelp(Help2, s, localError == null && !errorAtSearch);
    }

    /// Felder aus dem Kern nachführen – außer solange dort Getipptes noch nicht angekommen ist.
    void SyncFields(ManualInfo m)
    {
        foreach (var f in fields)
        {
            var v = f.Get(m);
            if (f.Pending)
            {
                if (v != f.Sent) continue;
                f.Pending = false;
            }
            if (f.Box.Text == v) continue;
            syncing = true;
            f.Box.Text = v;
            f.Box.CaretIndex = v.Length;
            syncing = false;
        }
    }

    static void SetText(TextBlock t, string text)
    {
        if (t.Text != text) t.Text = text;
    }

    static string? Problem(ManualInfo m, string key) => m.Problems.TryGetValue(key, out var p) ? p : null;

    /// Problem an Token/Schlüssel nur zeigen, wenn es mehr ist als „noch nicht fertig getippt“: falsche Zeichen im Feld
    /// oder volle Länge und trotzdem nicht gültig. Sonst reicht der graue Zähler.
    static string? CodeProblem(ManualInfo m, string key, string raw, int n, int total)
    {
        if (raw.Length == 0 || Problem(m, key) is not { } p) return null;
        var wrongChars = raw.Any(c => !Uri.IsHexDigit(c) && !char.IsWhiteSpace(c));
        return wrongChars || n >= total ? p : null;
    }

    static void Note(TextBlock note, string? text)
    {
        if (text == null)
        {
            note.Visibility = Visibility.Collapsed;
            return;
        }
        note.Text = text;
        note.Visibility = Visibility.Visible;
    }

    /// Zähler „37 von 128 Zeichen“ grau, vollständig grün; ein Problem des Kerns steht orange da.
    static void Count(TextBlock note, ContentControl mark, ref string? shown, int n, int total, string? problem)
    {
        var ok = problem == null && n == total;
        note.Text = problem ?? (ok ? $"{total} Zeichen" : $"{n} von {total} Zeichen");
        var key = problem != null ? "Warn" : ok ? "Ok" : "Sub";
        if (shown == key) return;
        shown = key;
        note.SetResourceReference(TextBlock.ForegroundProperty, key);
        var icon = Icons.Make(problem != null ? Icons.Warning : ok ? Icons.Check : SetupIcons.Circle, 12, null, ok ? 1.6 : 1.3);
        if (key == "Sub") icon.StrokeDashArray = new DoubleCollection { 1.5, 1.5 };
        icon.SetResourceReference(Shape.StrokeProperty, key);
        mark.Content = icon;
    }

    // MARK: Eingaben

    void Field_Changed(object sender, TextChangedEventArgs e)
    {
        var f = fields?.FirstOrDefault(x => x.Box == sender);
        if (f == null) return;
        f.Hint.Visibility = f.Box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (syncing) return;
        f.Sent = f.Box.Text;
        f.Pending = true;
        var err = Core.Send(Cmd.ManualSet, (f.Key, f.Box.Text));
        if (err == null) return;
        f.Pending = false;
        errorAtSearch = f.InSearch;
        localError = err;
        RenderMessages(Core.Snap.Setup);
    }

    // MARK: Aktionen

    void Report(string? error)
    {
        localError = error;
        Render();
    }

    void Back_Click(object sender, RoutedEventArgs e) => SetupView.Back();

    void Scan_Click(object sender, RoutedEventArgs e)
    {
        errorAtSearch = true;
        Report(Core.Send(Cmd.Scan));
    }

    void Subnet_Click(object sender, RoutedEventArgs e)
    {
        errorAtSearch = true;
        Report(Core.Send(Cmd.ScanSubnet));
    }

    /// Anlage aus der Suche übernehmen: Adresse, Port, Anlagen-ID kommen vom Kern (Token/Schlüssel bleiben).
    void Use(string id)
    {
        errorAtSearch = false;
        foreach (var f in fields) f.Pending = false;
        Report(Core.Send(Cmd.ManualUse, ("id", id)));
    }

    void Paste_Click(object sender, RoutedEventArgs e)
    {
        errorAtSearch = false;
        PastedNote.Visibility = Visibility.Collapsed;
        string text;
        try { text = Clipboard.ContainsText() ? Clipboard.GetText() : ""; }
        catch (Exception) { text = ""; } // Zwischenablage gerade von einem anderen Programm belegt
        var before = fields.Select(f => f.Box.Text).ToArray();
        foreach (var f in fields) f.Pending = false;
        var err = Core.Send(Cmd.ManualPaste, ("text", text));
        Report(err);
        if (err != null) return;
        // Was erkannt wurde, meldet der Kern nicht – nach dem Einlesen des neuen Zustands vergleichen (Send hat
        // Pumpen und Lesen schon eingereiht, dieselbe Priorität läuft danach).
        Dispatcher.InvokeAsync(() => ShowPasted(before), DispatcherPriority.Background);
    }

    void ShowPasted(string[] before)
    {
        if (Core.Snap.Setup.Path != "manual") return;
        var m = Core.Snap.Setup.Manual;
        var names = new List<string>();
        for (var i = 0; i < fields.Length; i++)
            if (fields[i].Get(m) != before[i]) names.Add(FieldName(fields[i].Key));
        PastedNote.Text = names.Count > 0 ? "Übernommen: " + string.Join(", ", names) : "Übernommen: keine Änderung";
        PastedNote.Visibility = Visibility.Visible;
    }

    static string FieldName(string key) => key switch
    {
        "ip" => "Adresse",
        "port" => "Port",
        "deviceId" => "Anlagen-ID",
        "token" => "Token",
        _ => "Schlüssel",
    };

    bool CanAct
    {
        get
        {
            var s = Core.Snap.Setup;
            return s.Manual.Complete && !s.Busy;
        }
    }

    void Check_Click(object sender, RoutedEventArgs e)
    {
        if (!CanAct) return;
        errorAtSearch = false;
        Report(Core.Send(Cmd.ManualCheck));
    }

    void Connect_Click(object sender, RoutedEventArgs e) => Connect();

    void Connect()
    {
        if (!CanAct) return;
        errorAtSearch = false;
        Report(Core.Send(Cmd.ManualConnect));
    }
}
