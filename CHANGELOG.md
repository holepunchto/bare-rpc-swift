# Changelog

Entries land under Unreleased and move to a version heading when that version is tagged.

## Unreleased

## 1.0.0

First stable release.

- Transport-agnostic `RPC` actor with an `RPCDelegate` for sending and receiving framed bytes.
- Request/reply, fire-and-forget events, and request, response, and bidirectional streaming.
- `CommandRouter` for dispatching incoming requests by command id.
- Wire-compatible with the JavaScript `bare-rpc` module and the C `librpc` library, verified by interop tests.
