# Public test keys

The P-256 signing key and matching public key were generated solely for the
isolated APNs unit tests. The P-384 key tests rejection of an unsupported signing
curve. None has been registered with Apple or used outside tests. These are
deliberately public test fixtures, not deployment credentials.

The tests verify signatures locally and use an injected fake transport. They
never contact APNs or send a notification.

To regenerate the fixtures from this directory:

```sh
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out test-signing-key.p8
openssl pkey -in test-signing-key.p8 -pubout -out test-public-key.pem
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out test-wrong-curve.p8
```

Use a separately issued Apple APNs key in production. Never copy a key from this
directory into service configuration.
