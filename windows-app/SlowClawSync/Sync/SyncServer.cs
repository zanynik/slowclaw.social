// SyncServer.cs — the LAN HTTP listener that serves the sync wire protocol.
//
// Desktop is the server; iOS is the client (scans the QR). The listener binds
// to one LAN interface, token-gates every request, and delegates all
// manifest/diff/apply logic to the Zig core via P/Invoke (the core owns sync
// logic; the shell owns transport — AGENTS.md §6.3). Starts when the Sync
// screen opens, stops on window close. Never a background daemon.

using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using SlowClawSync.Native;
using SlowClawSync.Storage;

namespace SlowClawSync.Sync;

internal sealed class SyncServer : IDisposable
{
    private readonly IntPtr _db;
    private readonly string _token;
    private readonly string _host;
    private readonly int _port;
    private HttpListener? _listener;
    private CancellationTokenSource? _cts;

    /// <summary>The QR payload the iOS client will scan.</summary>
    public QrPayload PairingPayload { get; }

    public SyncServer(IntPtr dbHandle, string host, int port, string token, string machineName)
    {
        _db = dbHandle;
        _host = host;
        _port = port;
        _token = token;
        PairingPayload = new QrPayload(1, host, port, token, machineName);
    }

    /// <summary>Start listening. Returns once the listener is bound.</summary>
    public void Start()
    {
        if (_listener is not null)
        {
            return;
        }
        _listener = new HttpListener();
        // Bind to the specific LAN interface (NOT 0.0.0.0) to avoid accidental
        // exposure on other interfaces. HttpListener requires a prefix.
        _listener.Prefixes.Add($"http://{_host}:{_port}/");
        _listener.Start();
        _cts = new CancellationTokenSource();
        _ = Task.Run(() => ListenLoop(_cts.Token));
    }

    /// <summary>Stop listening and release the socket.</summary>
    public void Stop()
    {
        _cts?.Cancel();
        _listener?.Stop();
    }

    private async Task ListenLoop(CancellationToken ct)
    {
        var listener = _listener!;
        while (!ct.IsCancellationRequested)
        {
            HttpListenerContext ctx;
            try
            {
                ctx = await listener.GetContextAsync().ConfigureAwait(false);
            }
            catch (HttpListenerException)
            {
                break; // listener stopped
            }
            // Handle on a background thread; don't block the accept loop.
            _ = Task.Run(() => HandleRequest(ctx));
        }
    }

    private void HandleRequest(HttpListenerContext ctx)
    {
        try
        {
            if (!CheckToken(ctx.Request))
            {
                Respond(ctx, 401, "unauthorized");
                return;
            }

            string path = ctx.Request.Url!.AbsolutePath;
            string method = ctx.Request.HttpMethod;

            switch ((method, path))
            {
                case ("GET", "/v1/manifest"):
                    HandleGetManifest(ctx);
                    break;
                case ("POST", "/v1/manifest"):
                    HandlePostManifest(ctx);
                    break;
                case ("GET", "/v1/entry"):
                    HandleGetEntry(ctx);
                    break;
                case ("GET", "/v1/media"):
                    HandleGetMedia(ctx);
                    break;
                case ("POST", "/v1/entry"):
                    HandlePostEntry(ctx);
                    break;
                case ("POST", "/v1/media"):
                    HandlePostMedia(ctx);
                    break;
                default:
                    Respond(ctx, 404, "not found");
                    break;
            }
        }
        catch (Exception)
        {
            // Never leak internals; a bare 500 is the safe response.
            try { Respond(ctx.Response, 500, "internal error"); } catch { }
        }
    }

    private bool CheckToken(HttpListenerRequest req)
    {
        string? auth = req.Headers["Authorization"];
        if (string.IsNullOrEmpty(auth))
        {
            return false;
        }
        const string prefix = "Bearer ";
        if (!auth.StartsWith(prefix, StringComparison.Ordinal))
        {
            return false;
        }
        // Constant-time compare to avoid timing-side-channel token guessing.
        string got = auth.Substring(prefix.Length).Trim();
        if (got.Length != _token.Length)
        {
            return false;
        }
        int diff = 0;
        for (int i = 0; i < got.Length; i++)
        {
            diff |= got[i] ^ _token[i];
        }
        return diff == 0;
    }

    // ── Endpoint handlers ────────────────────────────────────────────────

    private void HandleGetManifest(HttpListenerContext ctx)
    {
        SlowclawString outJson = default;
        int rc = SlowclawNative.slowclaw_feed_sync_build_manifest(
            _db, null, UIntPtr.Zero, ref outJson);
        if (rc != SlowclawNative.OK)
        {
            Respond(ctx.Response, 500, "build_manifest failed");
            return;
        }
        string? json = SlowClawNative.TakeString(ref outJson);
        Respond(ctx.Response, 200, json ?? "{}", "application/json");
    }

    private void HandlePostManifest(HttpListenerContext ctx)
    {
        // Body = the client's manifest. Diff: local=this server, remote=client.
        string clientManifest = ReadBody(ctx.Request);
        string serverManifest;
        SlowclawString serverOut = default;
        int rc = SlowclawNative.slowclaw_feed_sync_build_manifest(
            _db, null, UIntPtr.Zero, ref serverOut);
        if (rc != SlowClawNative.OK)
        {
            Respond(ctx.Response, 500, "build_manifest failed");
            return;
        }
        serverManifest = SlowClawNative.TakeString(ref serverOut) ?? "{}";

        SlowclawRankResult diffResult = default;
        rc = SlowclawNative.slowclaw_feed_sync_diff(
            SlowClawNative.Utf8(serverManifest), SlowClawNative.Len(serverManifest),
            SlowClawNative.Utf8(clientManifest), SlowClawNative.Len(clientManifest),
            ref diffResult);
        if (rc != SlowClawNative.OK)
        {
            Respond(ctx.Response, 400, "diff failed");
            return;
        }
        string? diff = SlowClawNative.TakeString(ref diffResult.items_json);
        SlowclawRankResult tmp = diffResult;
        SlowClawNative.slowclaw_feed_sync_result_free(ref tmp);
        Respond(ctx.Response, 200, diff ?? "{}", "application/json");
    }

    private void HandleGetEntry(HttpListenerContext ctx)
    {
        string? key = ctx.Request.QueryString["key"];
        if (string.IsNullOrEmpty(key))
        {
            Respond(ctx.Response, 400, "missing key");
            return;
        }
        SlowclawSqliteEntry entry = default;
        int rc = SlowclawNative.slowclaw_feed_sync_entry_for_transfer(
            _db, SlowClawNative.Utf8(key!), SlowClawNative.Len(key!), ref entry);
        if (rc == 1)
        {
            Respond(ctx.Response, 404, "not found");
            return;
        }
        if (rc != SlowClawNative.OK)
        {
            Respond(ctx.Response, 500, "entry_for_transfer failed");
            return;
        }
        // Project to the TransferEntry JSON shape (PROTOCOL.md GET /v1/entry).
        string json = JsonSerializer.Serialize(new
        {
            key = SlowClawNative.TakeString(ref entry.key),
            content = SlowClawNative.TakeString(ref entry.content),
            category = SlowClawNative.TakeString(ref entry.category),
            updated_at = SlowClawNative.TakeString(ref entry.timestamp), // updated_at stored as timestamp
            session_id = SlowClawNative.TakeString(ref entry.session_id),
            source = SlowClawNative.TakeString(ref entry.source),
            media_url = SlowClawNative.TakeString(ref entry.media_url),
        });
        SlowclawSqliteEntry tmp = entry;
        SlowClawNative.slowclaw_feed_sqlite_entry_free(ref tmp);
        Respond(ctx.Response, 200, json, "application/json");
    }

    private void HandlePostEntry(HttpListenerContext ctx)
    {
        // Wrap the single entry as a one-element array and apply via the core.
        string entryJson = ReadBody(ctx.Request);
        string arrayJson = "[" + entryJson + "]";
        int rc = SlowClawNative.slowclaw_feed_sync_apply_entries(
            _db, SlowClawNative.Utf8(arrayJson), SlowClawNative.Len(arrayJson));
        if (rc != SlowClawNative.OK)
        {
            Respond(ctx.Response, 400, "apply_entries failed");
            return;
        }
        Respond(ctx.Response, 200, "");
    }

    private void HandleGetMedia(HttpListenerContext ctx)
    {
        string? relPath = ctx.Request.QueryString["path"];
        if (string.IsNullOrEmpty(relPath))
        {
            Respond(ctx.Response, 400, "missing path");
            return;
        }
        // Resolve against the media root, guarding against path traversal.
        string full = Path.GetFullPath(Path.Combine(DatabasePath.MediaRoot, relPath!));
        string root = Path.GetFullPath(DatabasePath.MediaRoot);
        if (!full.StartsWith(root, StringComparison.OrdinalIgnoreCase))
        {
            Respond(ctx.Response, 400, "invalid path");
            return;
        }
        if (!File.Exists(full))
        {
            Respond(ctx.Response, 404, "not found");
            return;
        }
        ctx.Response.ContentType = full.EndsWith(".m4a", StringComparison.OrdinalIgnoreCase)
            ? "audio/m4a"
            : "application/octet-stream";
        // Range support for large files.
        using var fs = File.OpenRead(full);
        ctx.Response.ContentLength64 = fs.Length;
        if (ctx.Request.Headers["Range"] is string range)
        {
            // Minimal single-range support: "bytes=START-END" or "bytes=START-".
            if (ParseRange(range, fs.Length, out long start, out long end))
            {
                ctx.Response.StatusCode = 206;
                ctx.Response.AddHeader("Content-Range", $"bytes {start}-{end}/{fs.Length}");
                ctx.Response.ContentLength64 = end - start + 1;
                fs.Position = start;
                CopyLimited(fs, ctx.Response.OutputStream, end - start + 1);
                return;
            }
        }
        ctx.Response.StatusCode = 200;
        fs.CopyTo(ctx.Response.OutputStream);
    }

    private void HandlePostMedia(HttpListenerContext ctx)
    {
        string? relPath = ctx.Request.QueryString["path"];
        if (string.IsNullOrEmpty(relPath))
        {
            Respond(ctx.Response, 400, "missing path");
            return;
        }
        string full = Path.GetFullPath(Path.Combine(DatabasePath.MediaRoot, relPath!));
        string root = Path.GetFullPath(DatabasePath.MediaRoot);
        if (!full.StartsWith(root, StringComparison.OrdinalIgnoreCase))
        {
            Respond(ctx.Response, 400, "invalid path");
            return;
        }
        Directory.CreateDirectory(Path.GetDirectoryName(full)!);
        using (var fs = File.Create(full))
        {
            ctx.Request.InputStream.CopyTo(fs);
        }
        Respond(ctx.Response, 200, "");
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    private static string ReadBody(HttpListenerRequest req)
    {
        using var sr = new StreamReader(req.InputStream, Encoding.UTF8);
        return sr.ReadToEnd();
    }

    private static void Respond(HttpListenerResponse resp, int status, string body, string contentType = "text/plain")
    {
        resp.StatusCode = status;
        resp.ContentType = contentType;
        byte[] buf = Encoding.UTF8.GetBytes(body);
        resp.ContentLength64 = buf.Length;
        resp.OutputStream.Write(buf, 0, buf.Length);
    }

    private static void Respond(HttpListenerContext ctx, int status, string body) =>
        Respond(ctx.Response, status, body);

    private static bool ParseRange(string range, long length, out long start, out long end)
    {
        start = end = 0;
        const string p = "bytes=";
        if (!range.StartsWith(p, StringComparison.Ordinal))
        {
            return false;
        }
        string spec = range.Substring(p.Length);
        int dash = spec.IndexOf('-');
        if (dash < 0)
        {
            return false;
        }
        if (!long.TryParse(spec.Substring(0, dash), out start))
        {
            return false;
        }
        string endStr = spec.Substring(dash + 1);
        end = endStr.Length == 0 ? length - 1 : long.Parse(endStr);
        if (start < 0 || end >= length || start > end)
        {
            return false;
        }
        return true;
    }

    private static void CopyLimited(Stream src, Stream dst, long count)
    {
        byte[] buf = new byte[8192];
        long remaining = count;
        while (remaining > 0)
        {
            int toRead = (int)Math.Min(buf.Length, remaining);
            int n = src.Read(buf, 0, toRead);
            if (n == 0)
            {
                break;
            }
            dst.Write(buf, 0, n);
            remaining -= n;
        }
    }

    public void Dispose()
    {
        Stop();
        _listener?.Close();
        _cts?.Dispose();
    }
}
