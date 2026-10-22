import Foundation

/// Deterministic, process-stable hashing for per-image effect seeds.
///
/// Swift's `Hasher` / `hashValue` are randomly seeded per process, so they
/// can't back anything that must reproduce byte-for-byte across launches —
/// sidecars and exports must be reproducible. This uses two fixed-constant
/// algorithms instead:
///   - FNV-1a 64-bit maps an identity string (e.g. a file name) to a seed.
///   - SplitMix64 mixes that seed into independent derived values.
///
/// All arithmetic is intentionally wrapping (`&*`, `&+`) — overflow is the
/// mixing, not an error. The type is a value-free `enum` namespace, so it's
/// trivially `Sendable`.
enum StableHash {
    /// FNV-1a 64-bit hash over the UTF-8 bytes of `string`.
    static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV offset basis
        let prime: UInt64 = 0x0000_0100_0000_01b3 // FNV prime
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    /// One SplitMix64 mixing step. Deterministic and reversible-free: feed the
    /// returned value back in to derive a second independent value from the
    /// same seed.
    static func splitMix64(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9e37_79b9_7f4a_7c15
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    /// Stable 64-bit seed for an image identity string — typically the file's
    /// `lastPathComponent`. An empty identity maps to 0, the grain-neutral seed
    /// (offset (0,0), i.e. the pre-seed render).
    static func seed(for identity: String) -> UInt64 {
        guard !identity.isEmpty else { return 0 }
        return fnv1a(identity)
    }
}
