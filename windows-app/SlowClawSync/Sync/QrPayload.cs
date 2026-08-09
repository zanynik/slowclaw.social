// QrPayload.cs — builds the JSON payload encoded into the pairing QR.
// See PROTOCOL.md for the wire contract.

using System;
using System.Text.Json;

namespace SlowClawSync.Sync;

/// <param name="Version">Protocol version (currently 1).</param>
/// <param name="Host">Server LAN IPv4 address.</param>
/// <param name="Port">TCP port.</param>
/// <param name="Token">32 random bytes, base32 (RFC 4648, no padding).</param>
/// <param name="Name">Display name for the server (machine name).</param>
internal sealed record QrPayload(int Version, string Host, int Port, string Token, string Name)
{
    public string ToJson() => JsonSerializer.Serialize(new
    {
        v = Version,
        host = Host,
        port = Port,
        token = Token,
        name = Name,
    });

    /// <summary>Generate a fresh pairing token: 32 random bytes, base32-encoded
    /// (RFC 4648 alphabet, no padding). Regenerated per Sync session.</summary>
    public static string NewToken()
    {
        Span<byte> bytes = stackalloc byte[32];
        System.Security.Cryptography.RandomNumberGenerator.Fill(bytes);
        return Base32.Encode(bytes);
    }
}

/// <summary>RFC 4648 base32 (A-Z2-7), no padding. Compact encoding for the QR.</summary>
internal static class Base32
{
    private const string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

    public static string Encode(ReadOnlySpan<byte> data)
    {
        // 5 bits per char; 8 bytes -> 13 chars (ceil(64/5)=13). No padding.
        int bitCount = data.Length * 8;
        int charCount = (bitCount + 4) / 5;
        Span<char> output = stackalloc char[charCount];
        int buffer = 0;
        int bitsLeft = 0;
        int pos = 0;
        foreach (byte b in data)
        {
            buffer = (buffer << 8) | b;
            bitsLeft += 8;
            while (bitsLeft >= 5)
            {
                output[pos++] = Alphabet[(buffer >> (bitsLeft - 5)) & 0x1F];
                bitsLeft -= 5;
            }
        }
        if (bitsLeft > 0)
        {
            output[pos++] = Alphabet[(buffer << (5 - bitsLeft)) & 0x1F];
        }
        return new string(output.Slice(0, pos));
    }
}
