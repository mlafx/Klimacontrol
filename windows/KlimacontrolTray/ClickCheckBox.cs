using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;

namespace KlimacontrolTray;

/// CheckBox, deren Umschalten per Bedienungshilfe (UIA-Toggle, Sprachausgabe) wie ein Mausklick `Click` auslöst.
/// Die Standard-CheckBox ändert dabei nur `IsChecked` ohne `Click` – Handler an `Click` liefen dann nie.
public sealed class ClickCheckBox : CheckBox
{
    public ClickCheckBox() => SetResourceReference(StyleProperty, typeof(CheckBox));

    internal void ClickFromAutomation() => OnClick();

    protected override AutomationPeer OnCreateAutomationPeer() => new Peer(this);

    sealed class Peer(ClickCheckBox owner) : CheckBoxAutomationPeer(owner), IToggleProvider
    {
        void IToggleProvider.Toggle()
        {
            if (!IsEnabled()) throw new ElementNotEnabledException();
            owner.ClickFromAutomation();
        }
    }
}
