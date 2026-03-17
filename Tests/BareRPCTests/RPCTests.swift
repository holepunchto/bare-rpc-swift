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

func makePair(onRequest: ((IncomingRequest) async -> Void)? = nil) -> (client: RPC, server: RPC, delegates: (PipeDelegate, PipeDelegate)) {
  let da = PipeDelegate()
  let db = PipeDelegate()
  let a = RPC(delegate: da, onRequest: onRequest)
  let b = RPC(delegate: db, onRequest: onRequest)
  da.peer = b
  db.peer = a
  return (a, b, (da, db))
}

@Suite struct RPCTests {

  // Basic request/response: client sends request, server replies, client gets the data back.
  @Test func requestResponse() async throws {
    let (client, server, _delegates) = makePair()

    server.onRequest = { req in
      req.reply(req.data)
    }

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

  // Server rejects the request: client receives an error.
  @Test func requestRejection() async throws {
    let (client, server, _delegates) = makePair()
    server.onRequest = { req in req.reject("Oops", code: "ERR") }
    await #expect(throws: (any Error).self) {
      _ = try await client.request(1, data: nil)
    }
  }

  // Fire-and-forget event: server receives it but does not reply.
  @Test func event() async throws {
    let (client, server, _delegates) = makePair()

    try await confirmation { confirm in
      server.onRequest = { req in
        #expect(req.id == 0)
        #expect(req.command == 7)
        #expect(req.data == Data([0xBE, 0xEF]))
        confirm()
      }

      client.event(7, data: Data([0xBE, 0xEF]))
      try await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  // reply() on an event (id=0) must be a no-op, not crash.
  @Test func replyOnEventIsNoop() async throws {
    let (client, server, _delegates) = makePair()

    try await confirmation { confirm in
      server.onRequest = { req in
        req.reply(Data([1]))   // should be a no-op
        confirm()
      }

      client.event(1, data: nil)
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
    let (client, server, _delegates) = makePair()
    server.onRequest = { req in req.reply(req.data) }

    // Encode a request frame, then feed it to the server in two halves manually
    let payload = Data([10, 20, 30])
    let frame = Messages.encodeRequest(id: 1, command: 1, data: payload)
    let mid = frame.count / 2

    // Feed first half — not enough for a full frame
    server.receive(Data(frame[0..<mid]))
    // Feed second half — now the frame is complete
    // We need to capture the response, so set up the client to handle it
    // Actually, let's test via the server's onRequest handler
    try await confirmation { confirm in
      server.onRequest = { req in
        #expect(req.data == payload)
        confirm()
      }
      server.receive(Data(frame[mid...]))
      try await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  // Multiple frames in a single receive() call.
  @Test func multipleFramesInSingleReceive() async throws {
    let da = PipeDelegate()
    let server = RPC(delegate: da)

    let frame1 = Messages.encodeRequest(id: 0, command: 1, data: Data([1]))
    let frame2 = Messages.encodeRequest(id: 0, command: 2, data: Data([2]))

    var combined = Data()
    combined.append(frame1)
    combined.append(frame2)

    var commands: [Int] = []
    let lock = NSLock()

    try await confirmation(expectedCount: 2) { confirm in
      server.onRequest = { req in
        lock.withLock { commands.append(req.command) }
        confirm()
      }
      server.receive(combined)
      try await Task.sleep(nanoseconds: 100_000_000)
    }

    lock.withLock {
      #expect(commands.sorted() == [1, 2])
    }
  }

  // Streaming request with tracked id is rejected with an error response.
  @Test func streamingRequestRejection() async throws {
    // Build a streaming request frame (stream != 0) with a tracked id
    // We need to manually construct this since encodeRequest always sets stream=0
    var body = Data()
    body.append(1)    // type = 1 (request)
    body.append(5)    // id = 5
    body.append(1)    // command = 1
    body.append(1)    // stream = 1 (non-zero — streaming)
    body.append(0)    // data length = 0

    var frame = Data(count: 4)
    let len = UInt32(body.count)
    frame[0] = UInt8(len & 0xFF)
    frame[1] = UInt8((len >> 8) & 0xFF)
    frame[2] = UInt8((len >> 16) & 0xFF)
    frame[3] = UInt8((len >> 24) & 0xFF)
    frame.append(body)

    // Capture what the server sends back
    var sentData: Data?
    let captureDelegate = CaptureDelegate()

    let server = RPC(delegate: captureDelegate)
    captureDelegate.onSend = { data in sentData = data }

    server.receive(frame)
    try await Task.sleep(nanoseconds: 100_000_000)

    // Server should have sent a rejection response
    #expect(sentData != nil)
    if let response = sentData {
      let msg = try Messages.decodeFrame(response)
      guard case .response(let resp) = msg else { Issue.record("Expected response"); return }
      #expect(resp.id == 5)
      guard case .remoteError(let message, let code, _) = resp.result else {
        Issue.record("Expected remoteError rejection"); return
      }
      #expect(message == "Streaming not supported")
      #expect(code == "UNSUPPORTED")
    }
  }

  // Streaming event (id=0, stream!=0) is silently discarded — no rejection sent.
  @Test func streamingEventSilentlyDiscarded() async throws {
    var body = Data()
    body.append(1)    // type = 1 (request)
    body.append(0)    // id = 0 (event)
    body.append(1)    // command = 1
    body.append(1)    // stream = 1 (non-zero)
    body.append(0)    // data length = 0

    var frame = Data(count: 4)
    let len = UInt32(body.count)
    frame[0] = UInt8(len & 0xFF)
    frame[1] = UInt8((len >> 8) & 0xFF)
    frame[2] = UInt8((len >> 16) & 0xFF)
    frame[3] = UInt8((len >> 24) & 0xFF)
    frame.append(body)

    let captureDelegate = CaptureDelegate()
    var sentAnything = false
    captureDelegate.onSend = { _ in sentAnything = true }

    let server = RPC(delegate: captureDelegate)
    server.receive(frame)
    try await Task.sleep(nanoseconds: 100_000_000)

    #expect(sentAnything == false)
  }

  // Unknown message type is silently discarded.
  @Test func unknownMessageTypeDiscarded() async throws {
    var body = Data()
    body.append(99)   // type = 99 (unknown)

    var frame = Data(count: 4)
    let len = UInt32(body.count)
    frame[0] = UInt8(len & 0xFF)
    frame[1] = UInt8((len >> 8) & 0xFF)
    frame[2] = UInt8((len >> 16) & 0xFF)
    frame[3] = UInt8((len >> 24) & 0xFF)
    frame.append(body)

    let captureDelegate = CaptureDelegate()
    var sentAnything = false
    captureDelegate.onSend = { _ in sentAnything = true }

    let server = RPC(delegate: captureDelegate)
    server.onRequest = { _ in Issue.record("Should not receive unknown type as request") }
    server.receive(frame)
    try await Task.sleep(nanoseconds: 100_000_000)

    // Should not crash and should not send anything
    #expect(sentAnything == false)
  }

  // Error errno round-trip through RPC layer.
  @Test func errorErrnoRoundtrip() async throws {
    let (client, server, _delegates) = makePair()
    server.onRequest = { req in req.reject("fail", code: "ENOENT") }

    do {
      _ = try await client.request(1, data: nil)
      Issue.record("Expected error")
    } catch let err as NSError {
      #expect(err.domain == "ENOENT")
      #expect(err.userInfo[NSLocalizedDescriptionKey] as? String == "fail")
    }
  }
}

// Helper delegate that captures sent data for inspection.
class CaptureDelegate: RPCDelegate {
  var onSend: ((Data) -> Void)?
  func rpc(_ rpc: RPC, send data: Data) {
    onSend?(data)
  }
}
