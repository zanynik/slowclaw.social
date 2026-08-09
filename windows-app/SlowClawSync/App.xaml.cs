// App.xaml.cs — WinUI 3 application entry point. Unpackaged single-instance
// shell. The app does one thing: open the Sync window (renders the pairing QR,
// runs the LAN listener). No capture, no curation, no publishing.

using Microsoft.UI.Xaml;
using SlowClawSync.Storage;

namespace SlowClawSync;

public partial class App : Application
{
    private Window? _window;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        DatabasePath.EnsureDirectories();
        _window = new MainWindow();
        _window.Activate();
    }
}
