// Tests/BareRPCTests/RPCTests.swift
import Testing
@testable import BareRPC
import Foundation

// In-memory transport: connects two RPC instances so bytes flow directly between them.
class PipeDelegate: RPCDelegate {
  weak var peer: RPC?
  public func rpc(_ rpc: RPC, send data: Data) {
    peer?.receive(data)
  }
}

// Helper delegate that captures sent data for inspection.
class CaptureDelegate: RPCDelegate {
  var onSend: ((Data) -> Void)?
  func rpc(_ rpc: RPC, send data: Data) {
    onSend?(data)
  }
}

func makePair() -> (client: RPC, server: RPC, delegates: (PipeDelegate, PipeDelegate)) {
  let da = PipeDelegate()
  let db = PipeDelegate()
  let a = RPC(delegate: da)
  let b = RPC(delegate: db)
  da.peer = b
  db.peer = a
  return (a, b, (da, db))
}

@Suite struct RPCTests {

  // Basic request/response: client sends request, server replies, client gets the data back.
  @Test func requestResponse() async throws {
    let (client, server, _delegates) = makePair()
    server.onRequest = { req in req.reply(req.data) }

    let payload = Data([1, 2, 3])
    let response = try await client.request(42, data: payload)
    #expect(response == payload)
  }

  // Server returns no data (nil reply).
  @Test func requestWithNilResponse() async throws {
    let (client, server, _delegates) = makePair()
    server.onRequest = { req in req.reply(nil) }
    let response = try await client.request(1, data: nil)
    #expect(response == nil)
  }

  // Server rejects the request: client receives RPCRemoteError with all fields preserved.
  @Test func requestRejection() async throws {
    let (client, server, _delegates) = makePair()
    server.onRequest = { req in req.reject("Oops", code: "ERR", errno: -2) }

    do {
      _ = try await client.request(1, data: nil)
      Issue.record("Expected error")
    } catch let err as RPCRemoteError {
      #expect(err.message == "Oops")
      #expect(err.code == "ERR")
      #expect(err.errno == -2)
    }
  }

  // Fire-and-forget event: server receives it via onEvent, not onRequest.
  @Test func event() async throws {
    let (client, server, _delegates) = makePair()

    try await confirmation { confirm in
      server.onEvent = { event in
        #expect(event.command == 7)
        #expect(event.data == Data([0xBE, 0xEF]))
        confirm()
      }
      server.onRequest = { _ in Issue.record("Events should not trigger onRequest") }

      client.event(7, data: Data([0xBE, 0xEF]))
      try await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  // Multiple concurrent requests are correctly tracked by ID.
  @Test func concurrentRequests() async throws {
    let (client, server, _delegates) = makePair()
    server.onRequest = { req in req.reply(req.data) }

    async let r1 = client.request(1, data: Data([1]))
    async let r2 = client.request(2, data: Data([2]))
    async let r3 = client.request(3, data: Data([3]))

    let results = try await [r1, r2, r3]
    #expect(results[0] == Data([1]))
    #expect(results[1] == Data([2]))
    #expect(results[2] == Data([3]))
  }

  // Partial frame delivery: frame split across multiple receive() calls.
  @Test func partialFrameDelivery() async throws {
    let (_, server, _delegates) = makePair()

    let payload = Data([10, 20, 30])
    let frame = Messages.encodeRequest(id: 1, command: 1, data: payload)
    let mid = frame.count / 2

    // Feed first half — not enough for a full frame
    server.receive(Data(frame[0..<mid]))

    try await confirmation { confirm in
      server.onRequest = { req in
        #expect(req.data == payload)
        confirm()
      }
      // Feed second half — now the frame is complete
      server.receive(Data(frame[mid...]))
      try await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  // Multiple frames in a single receive() call.
  @Test func multipleFramesInSingleReceive() async throws {
    let server = RPC(delegate: CaptureDelegate())

    let frame1 = Messages.encodeRequest(id: 0, command: 1, data: Data([1]))
    let frame2 = Messages.encodeRequest(id: 0, command: 2, data: Data([2]))

    var combined = Data()
    combined.append(frame1)
    combined.append(frame2)

    var commands: [Int] = []
    let lock = NSLock()

    try await confirmation(expectedCount: 2) { confirm in
      server.onEvent = { event in
        lock.withLock { commands.append(event.command) }
        confirm()
      }
      server.receive(combined)
      try await Task.sleep(nanoseconds: 100_000_000)
    }

    lock.withLock {
      #expect(commands.sorted() == [1, 2])
    }
  }

  // Streaming request is silently discarded — no rejection sent, no onRequest called.
  @Test func streamingRequestSilentlyDiscarded() async throws {
    var body = Data()
    body.append(1)    // type = 1 (request)
    body.append(5)    // id = 5
    body.append(1)    // command = 1
    body.append(1)    // stream = 1 (non-zero — streaming)
    body.append(0)    // data length = 0

    let captureDelegate = CaptureDelegate()
    let lock = NSLock()
    var sentAnything = false
    captureDelegate.onSend = { _ in lock.withLock { sentAnything = true } }

    let server = RPC(delegate: captureDelegate)
    server.onRequest = { _ in Issue.record("Streaming requests should be silently discarded") }
    server.receive(makeRawFrame(body))
    try await Task.sleep(nanoseconds: 100_000_000)

    lock.withLock { #expect(sentAnything == false) }
  }

  // Streaming event (id=0, stream!=0) is silently discarded.
  @Test func streamingEventSilentlyDiscarded() async throws {
    var body = Data()
    body.append(1)    // type = 1 (request)
    body.append(0)    // id = 0 (event)
    body.append(1)    // command = 1
    body.append(1)    // stream = 1 (non-zero)
    body.append(0)    // data length = 0

    let captureDelegate = CaptureDelegate()
    let lock = NSLock()
    var sentAnything = false
    captureDelegate.onSend = { _ in lock.withLock { sentAnything = true } }

    let server = RPC(delegate: captureDelegate)
    server.onEvent = { _ in Issue.record("Streaming events should be silently discarded") }
    server.receive(makeRawFrame(body))
    try await Task.sleep(nanoseconds: 100_000_000)

    lock.withLock { #expect(sentAnything == false) }
  }

  // Unknown message type is silently discarded.
  @Test func unknownMessageTypeDiscarded() async throws {
    let captureDelegate = CaptureDelegate()
    let lock = NSLock()
    var sentAnything = false
    captureDelegate.onSend = { _ in lock.withLock { sentAnything = true } }

    let server = RPC(delegate: captureDelegate)
    server.onRequest = { _ in Issue.record("Should not receive unknown type as request") }
    server.receive(makeRawFrame(Data([99])))  // type=99 (unknown)
    try await Task.sleep(nanoseconds: 100_000_000)

    lock.withLock { #expect(sentAnything == false) }
  }

  // Malformed frame triggers onError callback.
  @Test func malformedFrameTriggersOnError() async throws {
    let server = RPC(delegate: CaptureDelegate())

    // A frame claiming 100 bytes of body but only providing 2
    // will be buffered until complete — so instead, provide a valid-length
    // frame with corrupt compact-encoded content
    var body = Data()
    body.append(1)     // type = 1 (request)
    body.append(0xFE)  // start of a varint that needs more bytes
    // truncated — decoding will fail

    try await confirmation { confirm in
      server.onError = { _ in confirm() }
      server.receive(makeRawFrame(body))
      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  // Error errno round-trip through RPC layer preserves all fields.
  @Test func errorErrnoRoundtrip() async throws {
    let (client, server, _delegates) = makePair()
    server.onRequest = { req in req.reject("fail", code: "ENOENT", errno: 42) }

    do {
      _ = try await client.request(1, data: nil)
      Issue.record("Expected error")
    } catch let err as RPCRemoteError {
      #expect(err.message == "fail")
      #expect(err.code == "ENOENT")
      #expect(err.errno == 42)
    }
  }
}
