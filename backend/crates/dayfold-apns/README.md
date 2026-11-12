# Dayfold APNs provider

`ApnsClient` sends one request per call and returns a classified outcome. The
worker persists retries and delivery state; this crate has no database or
filesystem dependencies. Cloned clients share HTTP connection pools and a JWT
cache. Configuration fixes the app topic, team, and key; requests choose only the
Apple sandbox or production environment.

The provider uses HTTP/2 over TLS, ES256 token authentication, a 20-minute JWT
reuse window, bounded network timeouts, no redirects, and no implicit transport
retries. Retry-After accepts seconds or HTTP dates with a 24-hour cap. Server
errors retain Apple's 15-minute minimum retry delay. Expired provider tokens can
trigger one early refresh; repeated authentication failure becomes permanent
instead of continuously minting tokens.

ES256 signing uses `jsonwebtoken`'s supported `aws_lc_rs` provider with PEM
decoding enabled. Keep `rust_crypto` disabled: it pulls in unrelated RSA support
and the affected `crypto-bigint` dependency chain. The workspace lockfile excludes
both packages; dependency audits must remain free of advisory suppressions.
See the [jsonwebtoken provider documentation](https://docs.rs/jsonwebtoken/11.1.0/jsonwebtoken/crypto/struct.CryptoProvider.html).

Calendar pushes contain a background hint and opaque notification/scope IDs.
Reminder alerts use fixed generic text, an opaque reminder ID, and its positive
revision. There is no event title, attendee, Google credential, or calendar
address in the payload. Consumers deduplicate notification IDs and compare a
reminder's revision with their local schedule before acting on it. A notification
already sent to Apple cannot be recalled after a later edit or cancellation.

`Outcome::Delivered` means APNs accepted the request, not that the device showed
it. `InvalidToken` includes APNs' 410 invalidation timestamp when available so
the worker can preserve a newer token registration. The returned permanent
failure codes are fixed strings; raw upstream bodies, keys, JWTs, and device
tokens must not be logged.

Run the isolated contract tests with:

```sh
cargo test --manifest-path backend/Cargo.toml -p dayfold-apns
```

The private transport and clock seam keeps all tests offline. Tests cover HTTP/2
request construction, headers, payload privacy, signature verification and
rotation, revision validation, retry classification, invalid-token timestamps,
and redacted diagnostics. See [public fixture documentation](tests/fixtures/README.md).

Protocol references:

- [Sending notification requests to APNs](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)
- [Handling notification responses from APNs](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns)
- [Establishing a token-based connection to APNs](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)
