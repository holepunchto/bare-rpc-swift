# Changelog

Entries land under Unreleased and move to a version heading when that version is tagged.

## Unreleased

- Fixed `IncomingStream.destroy(error:)` losing the error when a reader raced the frame send. The error is now handed to the consumer before suspending, so the stream throws rather than ending cleanly.

## 1.0.1

- An unrecognized message type now throws `MessagesError.unknownMessageType` instead of decoding to `nil`. A peer sending a type this format does not define fails the session rather than being ignored, matching the wire spec and the JS and C implementations.

## 1.0.0

First stable release.

- Transport-agnostic `RPC` actor with an `RPCDelegate` for sending and receiving framed bytes.
- Request/reply, fire-and-forget events, and request, response, and bidirectional streaming.
- `CommandRouter` for dispatching incoming requests by command id.
- Wire-compatible with the JavaScript `bare-rpc` module and the C `librpc` library, verified by interop tests.
