// MainWindow.xaml.cs — owns the Sync lifecycle: open the Zig store, start the
// LAN listener, render the pairing QR, show live entry count. Stops the
// listener on close (never a background daemon — AGENTS.md §1).

using System;
using System.IO;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;
using QRCoder;
using SlowClawSync.Native;
using SlowClawSync.Storage;
using SlowClawSync.Sync;

namespace SlowClawSync;

public sealed partial class MainWindow : Window
{
    private IntPtr _db;
    private SyncServer? _server;

    public MainWindow()
    {
        InitializeComponent();
        Title = "SlowClaw Sync";
        ExtendsContentIntoTitleBar = false;

        Closed += OnClosed;
        Loaded += OnLoaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        try
        {
            StartSync();
        }
        catch (Exception ex)
        {
            StatusText.Text = "Failed to start: " + ex.Message;
        }
    }

    private void StartSync()
    {
        // Open the Zig store.
        byte[] pathBytes = SlowClawNative.Utf8(DatabasePath.SqlitePath);
        _db = SlowClawNative.slowclaw_feed_sqlite_open(pathBytes, SlowClawNative.Len(pathBytes), IntPtr.Zero);
        if (_db == IntPtr.Zero)
        {
            StatusText.Text = "Could not open the SlowClaw database.";
            return;
        }

        // Detect the LAN address + generate a fresh pairing token.
        string host = LanInterface.DetectLanAddress();
        const int port = 8421;
        string token = QrPayload.NewToken();
        string name = Environment.MachineName;

        _server = new SyncServer(_db, host, port, token, name);
        _server.Start();

        // Render the QR (QRCoder PNG → BitmapImage).
        RenderQr(_server.PairingPayload.ToJson());

        StatusText.Text = $"Listening on {host}:{port} — scan with the SlowClaw iOS app.";
        UpdateCount();
    }

    private void RenderQr(string payload)
    {
        using var qrGenerator = new QRCodeGenerator();
        using var qrData = qrGenerator.CreateQrCode(payload, QRCodeGenerator.ECCLevel.M);
        // PngByteQRCode returns raw PNG bytes — no System.Drawing dependency
        // (keeps the app free of the legacy GDI+ stack on .NET 8).
        var pngCode = new PngByteQRCode(qrData);
        byte[] png = pngCode.GetGraphic(20);
        using var ms = new MemoryStream(png);
        var bmp = new BitmapImage();
        _ = bmp.SetSourceAsync(ms.AsRandomAccessStream()).AsTask();
        QrImage.Source = bmp;
    }

    private void UpdateCount()
    {
        if (_db == IntPtr.Zero)
        {
            return;
        }
        int count = SlowClawNative.slowclaw_feed_sqlite_count(_db);
        CountText.Text = $"{count} journal{(count == 1 ? "" : "s")} stored.";
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        _server?.Dispose();
        if (_db != IntPtr.Zero)
        {
            SlowClawNative.slowclaw_feed_sqlite_close(_db);
            _db = IntPtr.Zero;
        }
    }
}
