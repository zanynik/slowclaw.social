// SlowClawNative.cs — P/Invoke bindings to libslowclaw_feed.dll (the Zig core
// built for x86_64-windows by `zig build -Dtarget=x86_64-windows-msvc`).
//
// Mirrors the C ABI declared in ios-app/SlowClawFeed/include/slowclaw_feed.h.
// The Zig core allocates outputs with the C allocator; we free them via
// slowclaw_feed_free (the universal deallocator). Strings cross the ABI as
// (pointer, length) pairs and are NOT null-terminated.
//
// Only the sync + minimal sqlite surface is bound here — the Windows shell is
// sync-only (AGENTS.md §1); it does no ranking, inference, or curation.

using System;
using System.Runtime.InteropServices;

namespace SlowClawSync.Native;

internal static class SlowClawNative
{
    private const string Lib = "slowclaw_feed";

    [StructLayout(LayoutKind.Sequential)]
    internal struct SlowclawString
    {
        public IntPtr bytes;   // const uint8_t* ; NULL when empty
        public UIntPtr len;    // size_t
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct SlowclawSqliteEntry
    {
        public SlowclawString id;
        public SlowclawString key;
        public SlowclawString content;
        public SlowclawString category;
        public SlowclawString timestamp;
        public SlowclawString session_id;
        public SlowclawString source;
        public SlowclawString media_url;
        public double score;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct SlowclawRankResult
    {
        public SlowclawString items_json;
        public int status;
    }

    internal const int OK = 0;
    internal const int ERR_INVALID_ARGUMENT = -1;
    internal const int ERR_OUT_OF_MEMORY = -2;
    internal const int ERR_INTERNAL = -3;

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    private static extern void slowclaw_feed_free(IntPtr ptr);

    /// <summary>Open (or create) a SQLite DB at <paramref name="path"/>.</summary>
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr slowclaw_feed_sqlite_open(byte[] path, UIntPtr pathLen, IntPtr embedder);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void slowclaw_feed_sqlite_close(IntPtr handle);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int slowclaw_feed_sqlite_count(IntPtr handle);

    /// <summary>Insert or upsert a memory. Optional fields pass empty arrays.</summary>
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int slowclaw_feed_sqlite_store(
        IntPtr handle,
        byte[] key, UIntPtr keyLen,
        byte[] content, UIntPtr contentLen,
        byte[] category, UIntPtr categoryLen,
        byte[]? sessionId, UIntPtr sessionIdLen,
        byte[]? source, UIntPtr sourceLen,
        byte[]? mediaUrl, UIntPtr mediaUrlLen);

    // ── Sync exports ──────────────────────────────────────────────────────

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int slowclaw_feed_sync_build_manifest(
        IntPtr handle, byte[]? mediaRoot, UIntPtr mediaRootLen, ref SlowclawString outJson);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int slowclaw_feed_sync_diff(
        byte[] localJson, UIntPtr localLen,
        byte[] remoteJson, UIntPtr remoteLen,
        ref SlowclawRankResult outResult);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void slowclaw_feed_sync_result_free(ref SlowclawRankResult result);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int slowclaw_feed_sync_apply_entries(
        IntPtr handle, byte[] entriesJson, UIntPtr entriesLen);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int slowclaw_feed_sync_entry_for_transfer(
        IntPtr handle, byte[] key, UIntPtr keyLen, ref SlowclawSqliteEntry outEntry);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void slowclaw_feed_sqlite_entry_free(ref SlowclawSqliteEntry entry);

    // ── Helpers ───────────────────────────────────────────────────────────

    /// <summary>Read a Zig-owned SlowclawString into a managed string and free
    /// the Zig allocation. Returns null when bytes is NULL.</summary>
    internal static string? TakeString(ref SlowclawString s)
    {
        if (s.bytes == IntPtr.Zero || s.len == UIntPtr.Zero)
        {
            return null;
        }
        int len = checked((int)s.len);
        byte[] buf = new byte[len];
        Marshal.Copy(s.bytes, buf, 0, len);
        slowclaw_feed_free(s.bytes);
        s = default;
        return System.Text.Encoding.UTF8.GetString(buf);
    }

    /// <summary>UTF-8 encode a string for crossing the ABI (no null terminator
    /// added — the ABI uses (ptr,len) pairs).</summary>
    internal static byte[] Utf8(string s) => System.Text.Encoding.UTF8.GetBytes(s);

    internal static UIntPtr Len(byte[] b) => (UIntPtr)b.Length;
    internal static UIntPtr Len(byte[]? b) => b is null ? UIntPtr.Zero : (UIntPtr)b.Length;
}
