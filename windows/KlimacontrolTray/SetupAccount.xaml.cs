using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace KlimacontrolTray;

/// Weg „Mit Midea-Konto“: 1 Midea-Konto, 2 Anlage finden, 3 Verbinden. `SetupView` ruft `Render` bei jeder Änderung
/// des Kerns.
public partial class SetupAccount : UserControl
{
    static Core Core => Core.Shared;

    /// Schritt der zuletzt ausgelösten Aktion (Suche = 2, Verbinden = 3) – darunter erscheint die Fehlermeldung.
    int activeStep = 2;
    /// Sofortige Ablehnung eines Befehls durch den Kern (Rückgabe von Send) – gilt wie `Setup.Error`.
    string? localError;
    bool connectedOk;
    int setupSeq;

    readonly Border[] msgBoxes;
    readonly TextBlock[] msgTexts;
    readonly ContentControl[] msgIcons;
    readonly TextBlock scanLabel, subnetLabel, cloudLabel;
    readonly FoundCards found;

    public SetupAccount()
    {
        InitializeComponent();
        SetupUi.SetupSearch(ScanButton, out scanLabel, SubnetButton, out subnetLabel);
        CloudButton.Content = SetupUi.Labeled(Icons.Cloud, out cloudLabel);
        msgBoxes = new[] { Msg1, Msg2, Msg3 };
        msgTexts = new[] { MsgText1, MsgText2, MsgText3 };
        msgIcons = new[] { MsgIcon1, MsgIcon2, MsgIcon3 };
        found = new FoundCards(FoundList, false, id => Core.Send(Cmd.Select, ("id", id)));
        setupSeq = Core.Snap.Setup.Seq;
    }

    /// Passwort nicht im Speicher lassen (Fenster schließt bzw. Weg verlassen) und alte Meldungen wegräumen.
    public void Detach()
    {
        PasswordBox.Clear();
        localError = null;
        connectedOk = false;
        activeStep = 2;
    }

    /// Weg betreten: Abschlüsse des anderen Wegs (manualConnect zählt dieselbe Seq) nicht als eigene werten.
    public void Enter() => setupSeq = Core.Snap.Setup.Seq;

    /// Cursor ins E-Mail-Feld bzw. ins Passwort, wenn die E-Mail schon dasteht.
    public void FocusFirst()
    {
        if (AccountBox.Text.Length == 0) AccountBox.Focus();
        else PasswordBox.Focus();
    }

    string Account => AccountBox.Text.Trim();
    bool NeedsAccount => Account.Length == 0 || PasswordBox.Password.Length == 0;

    bool CanConnect(SetupInfo s) => s.Selected != null && !s.Busy && !NeedsAccount;

    // MARK: Darstellen

    public void Render()
    {
        var s = Core.Snap.Setup;
        // Platzhalter des Adressfelds vom Kern.
        var prompt = Core.Snap.Options.Credentials.AddressOrHostPrompt;
        if (IpHint.Text != prompt) IpHint.Text = prompt;

        // Verbinden abgeschlossen (Erfolg oder Fehler): Passwort löschen, Ergebnis zeigen.
        if (s.Seq != setupSeq)
        {
            setupSeq = s.Seq;
            PasswordBox.Clear();
            connectedOk = s.Ok;
            activeStep = 3;
        }

        SetupUi.RenderSearch(s, ScanButton, scanLabel, SubnetButton, subnetLabel);
        CheckButton.IsEnabled = IpBox.Text.Trim().Length > 0 && !s.Scanning;
        RenderCloudButton(s);
        found.Render(s);

        RenderConnectButton(s);
        var sel = s.Discovered.FirstOrDefault(d => d.Id == s.Selected);
        ConnectHint.Text = sel?.CloudOnly == true ? L.T("setup.view.connectHintCloudOnly") : L.T("setup.view.connectHintAccount");

        var error = localError ?? s.Error;
        for (var i = 0; i < msgBoxes.Length; i++)
        {
            var step = i + 1;
            if (error != null && step == activeStep) SetupUi.ShowMessage(msgBoxes[i], msgTexts[i], msgIcons[i], error, false);
            else if (error == null && connectedOk && step == 3 && !s.Busy) SetupUi.ShowMessage(msgBoxes[i], msgTexts[i], msgIcons[i], L.T("setup.view.windows.deviceSetUp"), true);
            else msgBoxes[i].Visibility = Visibility.Collapsed;
        }
        // Netzwerkhilfe nur unter Meldungen des Kerns, nicht bei sofortigen Ablehnungen.
        SetupUi.RenderHelp(Help2, s, localError == null && activeStep == 2);
        SetupUi.RenderHelp(Help3, s, localError == null && activeStep == 3);
    }

    void RenderCloudButton(SetupInfo s)
    {
        CloudButton.IsEnabled = !s.CloudScanning && !NeedsAccount;
        cloudLabel.Text = L.T(s.CloudScanning ? "setup.view.cloud.searching" : "setup.view.cloud.search");
        // Tooltip auch am ausgegrauten Knopf (ShowOnDisabled): er sagt, warum der Knopf aus ist.
        CloudButton.ToolTip = L.T(NeedsAccount ? "setup.view.cloud.needAccount" : "setup.view.cloud.help");
    }

    void RenderConnectButton(SetupInfo s)
    {
        ConnectButton.IsEnabled = CanConnect(s);
        ConnectButton.Content = L.T(s.Busy ? "setup.view.connecting" : "setup.view.connect");
    }

    // MARK: Eingaben

    void Input_Changed(object sender, TextChangedEventArgs e)
    {
        AccountHint.Visibility = AccountBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        IpHint.Visibility = IpBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        RefreshInputs();
    }

    void Password_Changed(object sender, RoutedEventArgs e)
    {
        PasswordHint.Visibility = PasswordBox.Password.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        RefreshInputs();
    }

    /// Nur die Knöpfe, die von den Eingabefeldern abhängen (kein ganzes Render je Tastendruck).
    void RefreshInputs()
    {
        if (!IsLoaded) return;
        var s = Core.Snap.Setup;
        RenderCloudButton(s);
        RenderConnectButton(s);
        CheckButton.IsEnabled = IpBox.Text.Trim().Length > 0 && !s.Scanning;
    }

    void Account_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        e.Handled = true;
        PasswordBox.Focus();
    }

    /// Enter im Passwort: verbinden, sobald das geht – sonst weiter zu Schritt 2 (IP-Feld).
    void Password_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        e.Handled = true;
        if (CanConnect(Core.Snap.Setup)) Connect();
        else IpBox.Focus();
    }

    void Ip_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        e.Handled = true;
        Check_Click(sender, e);
    }

    // MARK: Aktionen

    /// Fehler gehören ab jetzt unter `step`.
    void Begin(int step)
    {
        activeStep = step;
        localError = null;
        connectedOk = false;
    }

    void Report(string? error)
    {
        localError = error;
        Render();
    }

    void Back_Click(object sender, RoutedEventArgs e) => SetupView.Back();

    void Scan_Click(object sender, RoutedEventArgs e)
    {
        Begin(2);
        Report(Core.Send(Cmd.Scan));
    }

    void Subnet_Click(object sender, RoutedEventArgs e)
    {
        Begin(2);
        Report(Core.Send(Cmd.ScanSubnet));
    }

    void Cloud_Click(object sender, RoutedEventArgs e)
    {
        if (NeedsAccount) return;
        Begin(2);
        Report(Core.Send(Cmd.ScanCloud, ("account", Account), ("password", PasswordBox.Password)));
    }

    void Check_Click(object sender, RoutedEventArgs e)
    {
        var ip = IpBox.Text.Trim();
        if (ip.Length == 0 || Core.Snap.Setup.Scanning) return;
        Begin(2);
        Report(Core.Send(Cmd.Scan, ("ip", ip)));
    }

    void Connect_Click(object sender, RoutedEventArgs e) => Connect();

    void Connect()
    {
        if (!CanConnect(Core.Snap.Setup)) return;
        Begin(3);
        var err = Core.Send(Cmd.SetupConnect, ("account", Account), ("password", PasswordBox.Password));
        // Abgelehnt (kommt kein Abschluss mit neuer Seq): Passwort trotzdem nicht im Speicher lassen.
        if (err != null) PasswordBox.Clear();
        Report(err);
    }
}
