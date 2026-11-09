# bare-rpc-swift

RPC over any byte transport for Swift. The Swift counterpart of [bare-rpc](https://github.com/holepunchto/bare-rpc), and wire compatible with it. Built on [compact-encoding-swift](https://github.com/holepunchto/compact-encoding-swift).

```swift
dependencies: [
  .package(url: "https://github.com/holepunchto/bare-rpc-swift", from: "<tag>")
]

.product(name: "BareRPC", package: "bare-rpc-swift")
```

## Usage

This example wires two peers together in-process and makes one request:

```swift
import BareRPC
import Foundation

let (clientInput, toClient) = AsyncStream<Data>.makeStream()
let (serverInput, toServer) = AsyncStream<Data>.makeStream()

let server = RPC(
  AnyTransport(serverInput, write: { toClient.yield($0) }, close: { toClient.finish() }),
  onRequest: { request in try await request.reply(Data("pong".utf8)) }
)

let client = RPC(
  AnyTransport(clientInput, write: { toServer.yield($0) }, close: { toServer.finish() })
)

let reply = try await client.request(1, data: Data("ping".utf8))
print(String(decoding: reply!, as: UTF8.self))  // pong

await client.close()
await server.close()
```

`RPC` runs a session over a `Transport`. A `Transport` is an `AsyncSequence` of the `Data` that arrives from the peer, with an async `write(_:)` that sends data to the peer and an async `close()`. An `IPC` from [bare-stow-host-swift](https://github.com/holepunchto/bare-stow-host-swift) or [bare-kit-swift](https://github.com/holepunchto/bare-kit-swift) is a transport. `AnyTransport` builds one from its parts: An `AsyncSequence` of `Data` for the input, a `write:` closure, and an optional `close:` closure. The session writes one frame at a time, in order, so a slow transport holds back whoever is sending.

## Command routing

A `CommandRouter` sends each request and event to the handler registered for its command. Pass it to `RPC` as `handler:`:

```swift
let router = CommandRouter()

router.on(request: 1) { request in Data("pong".utf8) }
router.on(event: 2) { event in print(event.command) }

let rpc = RPC(transport, handler: router)
```

A request handler returns the data to reply with, unless it has answered the request itself. Commands without a handler go to the `delegate` of the router. By default, it rejects requests with the code `UNKNOWN_COMMAND` and drops events.

`CommandRouter` is a `Handler`. You can write your own `Handler` instead, with a `handle(_:)` method for requests and one for events. By default, the first rejects requests with the code `UNKNOWN_COMMAND` and the second drops events.

## Requests and responses

`request(_:data:)` sends a request and waits for its reply. `event(_:data:)` sends an event, which gets no reply, and waits for it to be written. Each request and event of the peer is handled in its own task, so a slow handler does not hold back the others.

A request is answered once, with `reply(_:)`, `reject(_:code:errno:)` or `createResponseStream()`. Answering again throws `RPCError.alreadySent`, and `sent` tells whether the request has been answered.

If a request handler throws before it answers, the request is rejected with the error. An `RPCRemoteError` is sent as is. Any other error is sent with its description as the message, an empty code and errno 0. If the handler had opened a response stream, the stream is destroyed with the error instead.

When the peer rejects a request, `request(_:data:)` throws an `RPCRemoteError` with the `message`, `code` and `errno` of the peer.

Without `onRequest:`, every request is rejected with the code `UNKNOWN_COMMAND`. Without `onEvent:`, events are dropped.

## Streaming requests and responses

A request can stream its body, its reply, or both:

- `createRequestStream(command:)` returns an `OutgoingStream` for the body. The reply is not read.
- `streamRequest(command:)` returns an `OutgoingStream` for the body and a `response` closure that waits for the reply.
- `requestWithResponseStream(command:data:)` sends a plain request and returns an `IncomingStream` for the reply.
- `createBidirectionalStream(command:)` returns an `OutgoingStream` for the body and an `IncomingStream` for the reply.

On the answering side, `createRequestStream()` returns the `IncomingStream` of the body, or `nil` if the request has none, and `createResponseStream()` returns an `OutgoingStream` for the reply. This handler echoes the body back:

```swift
let server = RPC(
  transport,
  onRequest: { request in
    guard let body = try await request.createRequestStream() else { return }
    let reply = try await request.createResponseStream()

    for try await chunk in body { try await reply.write(chunk) }
    await reply.end()
  }
)

let (outgoing, incoming) = try await client.createBidirectionalStream(command: 1)
try await outgoing.write(Data("ping".utf8))
await outgoing.end()

for try await chunk in incoming {
  print(String(decoding: chunk, as: UTF8.self))  // ping
}
```

A stream only carries data once both ends have opened it, so `write(_:)` and `end()` wait until the peer has opened its end. The handler opens the body when it calls `createRequestStream()`. If the peer answers before it opens the body, the body is not sent, and later writes are dropped. A write after `end()` or `destroy(error:)` is also dropped.

An `IncomingStream` asks the peer to pause once it buffers `highWaterMark` bytes, which is 16 KiB, and to resume once fewer bytes than that are buffered. While the peer has paused an `OutgoingStream`, `write(_:)` waits. If the peer keeps sending anyway, an incoming stream holds at most `maxBufferedBytes`, 16 MiB by default, before the session fails with `RPCError.streamOverflow`.

The body of a request and the reply of `streamRequest(command:)` can each be read once. Calling `createRequestStream()` or `response()` again throws `RPCError.alreadyReceived`. Read an `IncomingStream` with `for try await`.

## Cancellation

Cancelling the task that waits for an answer cancels the request. This applies to `request(_:data:timeout:)`, `requestWithResponseStream(command:data:)`, `createBidirectionalStream(command:)`, and the `response` closure of `streamRequest(command:)`. The waiting call throws `CancellationError`, the body stream of the request fails with it, and the peer is told to stop handling the request. Once the answer has arrived, cancelling does nothing, and a task that is already cancelled sends no request at all.

`request(_:data:timeout:)` also takes a `timeout` in seconds. If no reply arrives in time, the request is cancelled and the call throws `RPCError.timeout`:

```swift
let reply = try await rpc.request(1, data: Data("ping".utf8), timeout: 5)
```

On the answering side, a cancel of the peer cancels the task of the handler, so `Task.isCancelled`, `Task.checkCancellation()` and cancellable calls such as `Task.sleep` see it. `cancellationError` holds the `message`, `code` and `errno` that the peer cancelled with, with the code `CANCELLED` or `TIMEOUT` when the peer is another bare-rpc. The streams of the request end as if the peer had destroyed them with that error: reading the body throws it, and writes to the reply stream are dropped. Answering the request sends nothing:

```swift
router.on(request: 1) { request in
  let result = try await search(request.data)  // Throws once the peer cancels
  return result
}
```

When the session ends, the tasks of the handlers that are still running are cancelled too.

Cancelling a request needs a peer that supports it. A peer without support fails the session with `RPCError.unknownMessage` when it receives a cancel.

## Termination

The session ends with `RPCError.channelClosed` when you call `close()` or the transport finishes. It fails with an error instead when:

- The transport finishes partway through a frame, with `RPCError.invalidMessage`.
- Reading from or writing to the transport throws, with that error.
- An event handler throws, with that error.
- The peer sends a bad frame, as described under [Untrusted peers](#untrusted-peers).

Pending requests then throw the error, and so do later requests. Open incoming streams fail with it, and writes to open outgoing streams throw it. The tasks of running handlers are cancelled. Events sent after the end are dropped.

The session then stops reading and closes the transport. If it ended with `RPCError.channelClosed`, it first writes the frames already queued. Otherwise it drops them.

`close()` waits for the transport to close. `wait()` waits for the session to end. It returns if the session ended with `RPCError.channelClosed`, and throws the error otherwise:

```swift
do {
  try await rpc.wait()
} catch {
  print("The session failed: \(error)")
}
```

## Untrusted peers

`RPC` does not trust the peer to send valid frames. If a frame is longer than `maxFrameSize`, cannot be decoded, or breaks the protocol, the session fails with an `RPCError`. The case tells you why:

- `frameTooLarge`: The frame, with its length prefix, is longer than `maxFrameSize`. This is checked as soon as the length prefix arrives, before the rest of the frame is read.
- `unknownMessage`: The frame has a message type that `RPC` does not know.
- `invalidMessage`: The frame cannot be decoded, the transport ends partway through a frame, or the frame is one that a valid peer never sends. Examples are a response, stream or cancel message with an id of 0, a stream message with an invalid set of flags, and a new request that reuses the id of a request that is still in flight.
- `streamOverflow`: An incoming stream holds more than `maxBufferedBytes` bytes that have not been read. This only happens when the peer keeps sending after it was asked to pause.

A frame that refers to a request or stream that has already finished, or that was never known, is ignored. The same goes for frames that arrive for a stream that has already ended or been destroyed.

If you read the reply as a stream but the peer replies without one, the reply arrives on the stream as a single chunk, unless it is empty, and the stream then ends. An error reply makes the call throw the error instead of returning a stream.

If you expect a plain reply but the peer replies with a stream, the call throws `RPCError.unexpectedStream`. The session destroys the stream toward the peer and stays open.

## License

Apache-2.0
