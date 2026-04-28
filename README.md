# bare-rpc-swift

Swift implementation of the [`bare-rpc`](https://github.com/holepunchto/bare-rpc)
protocol — a binary RPC framework using compact encoding over arbitrary
transports. Wire-compatible with the JavaScript `bare-rpc` module and the C
`librpc` library.

## Build & test

```sh
swift build
swift test
```

The full Swift test suite runs without any external setup. Two tests in
`BareInteropTests` additionally spawn a live JavaScript peer; without a peer
they print a skip notice and pass.

### Live JS interop (optional locally, required in CI)

To run the live interop tests locally:

```sh
npm install -g bare
(cd Tests/BareRPCTests/Fixtures && npm install)
swift test --filter BareInteropTests
```

Both prerequisites are wired up automatically in CI. CI runs with `CI=true`,
which turns missing prerequisites into hard failures so a misconfigured
runner can't silently no-op past the live tests.
