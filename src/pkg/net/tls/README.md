# TLS Package

Client-side TLS 1.2 / TLS 1.3 implementation, generic over transport (`net.Conn`), cryptography (`Crypto`), and synchronization (`Mutex`).

## Architecture

```
stream.zig      High-level API — wraps Conn into TLS stream (satisfies net.Conn itself)
  └── client.zig    Thread-safe Client — mutex-protected send/recv, close_notify handling
        └── handshake.zig   Handshake state machine — ClientHello → Finished
              ├── record.zig      Record layer — framing, AEAD encrypt/decrypt
              ├── extensions.zig  TLS extension builder/parser
              └── kdf.zig         HKDF-Expand-Label (RFC 8446 §7.1)

common.zig      Protocol constants, enums, cipher suite properties
alert.zig       Alert message handling and error mapping
stress_test.zig Integration tests over real TCP loopback
```

## Supported

- **TLS 1.3** (RFC 8446): full handshake with X25519 key exchange
- **TLS 1.2** (RFC 5246): ECDHE key exchange with X25519 / P-256
- **Cipher suites**: AES-128-GCM, AES-256-GCM, ChaCha20-Poly1305
- **Signature verification**: ECDSA P-256/P-384, RSA PKCS#1 v1.5, RSA-PSS (2048/4096-bit)
- **Certificate chain verification**: via `Crypto.x509` (std platform uses system CA bundle)
- **Hostname verification**: SAN / CN matching
- **Thread safety**: separate read/write mutexes, atomic state flags
- **Transport agnostic**: works over any `net.Conn` (TCP, pipe, memory, etc.)

## Known Limitations

### SHA-256 only key derivation

HKDF, PRF, and TranscriptHash are hardcoded to SHA-256. If `TLS_AES_256_GCM_SHA384` is negotiated, key derivation still uses SHA-256 instead of SHA-384. This is safe today because the ClientHello only offers AES-128-GCM as the TLS 1.3 suite, but must be addressed before adding SHA-384 suites to the offer list.

**Impact**: None with current cipher suite configuration.
**Fix**: Parameterize hash algorithm selection based on negotiated cipher suite.

### No HelloRetryRequest support

If the server responds with HelloRetryRequest (server_random = HRR magic), the handshake returns `error.HelloRetryNotSupported`. Most servers accept X25519 on the first try.

**Impact**: Rare. Only affects servers that reject the initial key share group.
**Fix**: Implement HRR by re-sending ClientHello with the server's preferred group.

### RSA key sizes limited to 2048 / 4096 bit

`verifyRsaPkcs1` and `verifyRsaPss` only handle modulus lengths of 256 bytes (2048-bit) and 512 bytes (4096-bit). 3072-bit keys (384 bytes) are rejected as `UnsupportedSignatureAlgorithm`.

**Impact**: Low. 2048 and 4096 are the dominant sizes. Some CAs use 3072.
**Fix**: Add a 384-byte branch in `verifyRsaPkcs1` / `verifyRsaPss`.

### No session resumption / 0-RTT

TLS 1.3 session tickets (`NewSessionTicket`) are received but ignored. No PSK-based resumption or 0-RTT early data.

**Impact**: Every connection performs a full handshake.
**Fix**: Store session tickets, implement PSK binder in ClientHello.

### No client certificate authentication

The implementation does not handle `CertificateRequest` from the server. Mutual TLS is not supported.

**Impact**: Cannot connect to servers requiring client certificates.
**Fix**: Add CertificateRequest handling and client cert/key configuration.

### No key update

TLS 1.3 `KeyUpdate` messages are not handled. Long-lived connections that exceed the cipher's safe usage limit will not rotate keys.

**Impact**: Only affects very long-lived connections (billions of records).
**Fix**: Handle `KeyUpdate` handshake message, re-derive traffic keys.

### No ALPN negotiation result

ALPN protocols are sent in ClientHello but the server's selection in EncryptedExtensions is not parsed or exposed.

**Impact**: Cannot determine which application protocol was negotiated (e.g. h2 vs http/1.1).
**Fix**: Parse ALPN extension in `processEncryptedExtensions`, expose via getter.

## Testing

TLS tests live under `test/unit/pkg/net/tls/` and are pulled in by `test/unit/mod.zig`.

```bash
cd test/unit && zig build test
```

`stress_test.zig` (TCP loopback stress) is **not** imported from `mod.zig` by default. To run it, add `_ = @import("pkg/net/tls/stress_test.zig");` to `test/unit/mod.zig`, then `cd test/unit && zig build test`.
