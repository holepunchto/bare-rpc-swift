# bare-rpc-swift

Swift implementation of the [`bare-rpc`](https://github.com/holepunchto/bare-rpc) protocol - a binary RPC framework using compact encoding over arbitrary transports. Wire-compatible with the JavaScript `bare-rpc` module and the C `librpc` library.

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/holepunchto/bare-rpc-swift", from: "1.0.0")
]
```

Then add `BareRPC` to your target's dependencies:

```swift
.target(
  name: "MyTarget",
  dependencies: [
    .product(name: "BareRPC", package: "bare-rpc-swift")
  ]
)
```

## Usage

`RPC` is transport-agnostic. You supply an `RPCDelegate`: `rpc(_:send:)` pushes framed bytes onto your wire, and you feed bytes arriving from the wire back in with `rpc.receive(_:)`. Incoming requests are delivered to `rpc(_:didReceiveRequest:)`.

This example wires two peers together in-process:

```swift
import BareRPC
import Foundation

final class Loopback: RPCDelegate {
  weak var peer: RPC?

  // Ship outgoing bytes to the other peer.
  func rpc(_ rpc: RPC, send data: Data) {
    Task { await peer?.receive(data) }
  }

  // Handle an incoming request and reply to it.
  func rpc(_ rpc: RPC, didReceiveRequest request: IncomingRequest) async throws {
    if request.command == 42 {
      await request.reply("pong".data(using: .utf8))
    }
  }
}

let clientSide = Loopback()
let serverSide = Loopback()

let client = RPC(delegate: clientSide)
let server = RPC(delegate: serverSide)

clientSide.peer = server
serverSide.peer = client

let reply = try await client.request(42, data: "ping".data(using: .utf8))
print(String(data: reply!, encoding: .utf8)!)  // pong
```

For fire-and-forget messages use `event(_:data:)`, delivered to `rpc(_:didReceiveEvent:)`. `RPC` also supports streaming requests and responses; see `createRequestStream`, `streamRequest`, `requestWithResponseStream`, and `createBidirectionalStream`.

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

## License

Apache-2.0
