using System.Windows;

namespace Uncapped;

/// <summary>
/// Tells the player which addons are theirs rather than ours, once.
///
/// A plain MessageBox cannot carry a "do not show again" checkbox, and this warning has to
/// have one: it fires on every launch otherwise, and a warning that appears every single time
/// stops being read by the third time. Someone running a stack of third-party addons
/// deliberately does not need telling about it forever.
/// </summary>
public partial class AddOnWarningWindow : Window
{
    public bool DoNotAskAgain { get; private set; }

    public AddOnWarningWindow(IEnumerable<string> addOns)
    {
        InitializeComponent();
        AddOnList.ItemsSource = addOns.ToList();
    }

    private void OnOk(object sender, RoutedEventArgs e)
    {
        DoNotAskAgain = DontAskAgain.IsChecked == true;
        DialogResult = true;
        Close();
    }
}
