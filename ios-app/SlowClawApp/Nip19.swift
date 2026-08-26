// Nip19.swift — minimal NIP-19 naddr encoder for Nostr article links.
//
// Mirrors encodeNaddr in web/src/lib/nostr.ts so the iOS app produces the
// same naddr bech32 strings the reference app does. Long-form readers
// (highlighter.com — habla.news is offline) decode with nostr-tools, which
// uses plain bech32 (constant 1), NOT bech32m — so we must too.
//
// naddr TLV layout (NIP-19):
//   type 0 = identifier (the NIP-33 "d" tag)   — UTF-8 bytes
//   type 2 = author pubkey                      — 32 bytes
//   type 3 = kind                               — 4-byte big-endian u32
// (type 1 = relay URL, optional, omitted here.)
// Each TLV entry: [type:u8][length:u8][value bytes]. Length is a single byte.

import Foundation

enum Nip19 {
    private static let charset: [Character] = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    /// Encode an naddr. Returns nil if the pubkey isn't a valid 32-byte hex.
    /// `identifier` is the "d" tag; `pubkey` is the 64-char hex pubkey; `kind` is the event kind.
    static func encodeNaddr(
        identifier: String,
        pubkey: String,
        kind: UInt32,
        relay: String? = nil
    ) -> String? {
        guard let pkBytes = hexBytes(pubkey), pkBytes.count == 32 else { return nil }
        var tlv: [UInt8] = []
        let idBytes = Array(identifier.utf8)
        // TLV lengths are one byte. Reject oversized values instead of
        // truncating them into an naddr that resolves to another article.
        guard idBytes.count <= Int(UInt8.max) else { return nil }
        pushTlv(&tlv, type: 0, value: idBytes)
        if let relay, !relay.isEmpty {
            let relayBytes = Array(relay.utf8)
            guard relayBytes.count <= Int(UInt8.max) else { return nil }
            pushTlv(&tlv, type: 1, value: relayBytes)
        }
        pushTlv(&tlv, type: 2, value: pkBytes)
        pushTlv(&tlv, type: 3, value: [
            UInt8((kind >> 24) & 0xff), UInt8((kind >> 16) & 0xff),
            UInt8((kind >> 8) & 0xff), UInt8(kind & 0xff),
        ])

        let data = convertBits(tlv, fromBits: 8, toBits: 5, pad: true)
        let checksum = bech32CreateChecksum(hrp: "naddr", data: data, constant: 1)
        var result = "naddr1"
        for v in data + checksum {
            // charset is ASCII; safe to subscript.
            result.append(charset[Int(v)])
        }
        return result
    }

    private static func pushTlv(_ out: inout [UInt8], type: UInt8, value: [UInt8]) {
        out.append(type)
        out.append(UInt8(value.count))
        out.append(contentsOf: value)
    }

    /// Decode a hex string to bytes.
    private static func hexBytes(_ s: String) -> [UInt8]? {
        guard s.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        return bytes
    }

    // ── bech32 primitives ──────────────────────────────────────────────────

    private static func bech32Polymod(_ values: [UInt8]) -> UInt32 {
        let gen: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var chk: UInt32 = 1
        for v in values {
            let top = chk >> 25
            chk = ((chk & 0x1ffffff) << 5) ^ UInt32(v)
            for i in 0..<5 {
                if (top >> i) & 1 != 0 { chk ^= gen[i] }
            }
        }
        return chk
    }

    private static func bech32HrpExpand(_ hrp: String) -> [UInt8] {
        var ret: [UInt8] = []
        for c in hrp.utf8 { ret.append(c >> 5) }
        ret.append(0)
        for c in hrp.utf8 { ret.append(c & 31) }
        return ret
    }

    private static func bech32CreateChecksum(hrp: String, data: [UInt8], constant: UInt32) -> [UInt8] {
        var values = bech32HrpExpand(hrp) + data
        values += [0, 0, 0, 0, 0, 0]
        let mod = bech32Polymod(values) ^ constant
        var ret: [UInt8] = []
        for i in 0..<6 {
            ret.append(UInt8((mod >> UInt32(5 * (5 - i))) & 31))
        }
        return ret
    }

    /// Generic bit-group converter (8→5 for bech32 data part).
    private static func convertBits(_ data: [UInt8], fromBits: Int, toBits: Int, pad: Bool) -> [UInt8] {
        var acc = 0
        var bits = 0
        var ret: [UInt8] = []
        let maxv = (1 << toBits) - 1
        let maxAcc = (1 << (fromBits + toBits - 1)) - 1
        for value in data {
            if (value >> fromBits) != 0 { return [] }
            acc = ((acc << fromBits) | Int(value)) & maxAcc
            bits += fromBits
            while bits >= toBits {
                bits -= toBits
                ret.append(UInt8((acc >> bits) & maxv))
            }
        }
        if pad {
            if bits != 0 { ret.append(UInt8((acc << (toBits - bits)) & maxv)) }
        } else if bits >= fromBits || (acc << (toBits - bits)) & maxv != 0 {
            return []
        }
        return ret
    }
}
