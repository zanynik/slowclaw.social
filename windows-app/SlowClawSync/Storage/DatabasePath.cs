// DatabasePath.cs — resolves the on-disk locations for the Windows companion.
//
// The Windows shell mirrors the iOS app's layout: a single SQLite DB at
// %LOCALAPPDATA%\SlowClaw\slowclaw.sqlite plus a sibling Documents tree for
// audio media (Recordings/, Inbox/). The Zig core owns the DB; this helper
// just makes sure the directories exist and hands the path to the FFI.

using System;
using System.IO;

namespace SlowClawSync.Storage;

internal static class DatabasePath
{
    /// <summary>The per-user app data root: %LOCALAPPDATA%\SlowClaw.</summary>
    public static string AppRoot
    {
        get
        {
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            return Path.Combine(local, "SlowClaw");
        }
    }

    /// <summary>The SQLite DB path consumed by slowclaw_feed_sqlite_open.</summary>
    public static string SqlitePath => Path.Combine(AppRoot, "slowclaw.sqlite");

    /// <summary>The media root (Documents-equivalent). media_url paths from the
    /// iOS side (e.g. "Recordings/journal_1234.m4a") resolve under here.</summary>
    public static string MediaRoot => Path.Combine(AppRoot, "Documents");

    /// <summary>Ensure AppRoot + MediaRoot + Recordings/ exist. Safe to call
    /// repeatedly.</summary>
    public static void EnsureDirectories()
    {
        Directory.CreateDirectory(AppRoot);
        Directory.CreateDirectory(MediaRoot);
        Directory.CreateDirectory(Path.Combine(MediaRoot, "Recordings"));
        Directory.CreateDirectory(Path.Combine(MediaRoot, "Inbox"));
    }
}
