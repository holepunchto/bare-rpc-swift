# bare-rpc-swift

Swift implementation of the [`bare-rpc`](https://github.com/holepunchto/bare-rpc) protocol — a binary RPC framework using compact encoding over arbitrary transports. Wire-compatible with the JavaScript `bare-rpc` module and the C `librpc` library.

## Build & test

```sh
swift build
swift test
```

`BareInteropTests` spawns a live JS peer via `bare`. Tests skip locally without it; CI (`CI=true`) treats missing prerequisites as hard failures.

```sh
npm install -g bare-runtime
npm install
swift test --filter BareInteropTests
```
