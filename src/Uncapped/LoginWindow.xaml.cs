using System.Windows;
using System.Windows.Input;
using Uncapped.Model;

namespace Uncapped;

public partial class LoginWindow : Window
{
    public Credentials Result { get; private set; }

    public LoginWindow(Credentials existing)
    {
        InitializeComponent();

        Result = existing;
        AccountBox.Text = existing.AccountName;
        PasswordBox.Password = existing.Password;

        ForgetButton.Visibility = existing.HasPassword || existing.HasAccountName
            ? Visibility.Visible
            : Visibility.Collapsed;

        MouseLeftButtonDown += (_, e) => { if (e.ButtonState == MouseButtonState.Pressed) DragMove(); };
        Loaded += (_, _) => AccountBox.Focus();
    }

    /// <summary>Keeps the two boxes in step so toggling reveal never loses what was typed.</summary>
    private void OnToggleReveal(object sender, RoutedEventArgs e)
    {
        if (ShowPassword.IsChecked == true)
        {
            PasswordPlainBox.Text = PasswordBox.Password;
            PasswordPlainBox.Visibility = Visibility.Visible;
            PasswordBox.Visibility = Visibility.Collapsed;
        }
        else
        {
            PasswordBox.Password = PasswordPlainBox.Text;
            PasswordBox.Visibility = Visibility.Visible;
            PasswordPlainBox.Visibility = Visibility.Collapsed;
        }
    }

    private string CurrentPassword =>
        ShowPassword.IsChecked == true ? PasswordPlainBox.Text : PasswordBox.Password;

    private void OnSave(object sender, RoutedEventArgs e)
    {
        Result = new Credentials
        {
            AccountName = AccountBox.Text.Trim(),
            Password = CurrentPassword,
        };
        Result.Save();

        DialogResult = true;
        Close();
    }

    private void OnForget(object sender, RoutedEventArgs e)
    {
        var confirm = MessageBox.Show(
            "Forget the saved account name and password?",
            "Saved login", MessageBoxButton.YesNo, MessageBoxImage.Question);

        if (confirm != MessageBoxResult.Yes) return;

        Credentials.Delete();
        Result = new Credentials();

        DialogResult = true;
        Close();
    }

    private void OnClose(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }
}
