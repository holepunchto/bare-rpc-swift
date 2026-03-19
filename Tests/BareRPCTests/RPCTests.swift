import Foundation
import Testing

@testable import BareRPC

class PipeDelegate: RPCDelegate {
  weak var peer: RPC?
  public func rpc(_ rpc: RPC, send data: Data) {
    peer?.receive(data)
  }
}

class CaptureDelegate: RPCDelegate {
  var onSend: ((Data) -> Void)?
  func rpc(_ rpc: RPC, send data: Data) {
    onSend?(data)
  }
}

struct RPCPair {
  let client: RPC
  let server: RPC
  private let _delegates: (PipeDelegate, PipeDelegate)

  init() {
    let da = PipeDelegate()
    let db = PipeDelegate()
    client = RPC(delegate: da)
    server = RPC(delegate: db)
    da.peer = server
    db.peer = client
    _delegates = (da, db)
  }
}

@Suite struct RPCTests {

  @Test func requestResponse() async throws {
    let pair = RPCPair()
    pair.server.onRequest = { req in req.reply(req.data) }

    let payload = Data([1, 2, 3])
    let response = try await pair.client.request(42, data: payload)
    #expect(response == payload)
  }

  @Test func requestWithNilResponse() async throws {
    let pair = RPCPair()
    pair.server.onRequest = { req in req.reply(nil) }
    let response = try await pair.client.request(1, data: nil)
    #expect(response == nil)
  }

  @Test func requestRejection() async throws {
    let pair = RPCPair()
    pair.server.onRequest = { req in req.reject("Oops", code: "ERR", errno: -2) }

    do {
      _ = try await pair.client.request(1, data: nil)
      Issue.record("Expected error")
    } catch let err as RPCRemoteError {
      #expect(err.message == "Oops")
      #expect(err.code == "ERR")
      #expect(err.errno == -2)
    }
  }

  @Test func event() async throws {
    let pair = RPCPair()

    try await confirmation { confirm in
      pair.server.onEvent = { event in
        #expect(event.command == 7)
        #expect(event.data == Data([0xBE, 0xEF]))
        confirm()
      }
      pair.server.onRequest = { _ in Issue.record("Events should not trigger onRequest") }

      pair.client.event(7, data: Data([0xBE, 0xEF]))
      try await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  @Test func partialFrameDelivery() async throws {
    let pair = RPCPair()

    let payload = Data([10, 20, 30])
    let frame = Messages.encodeRequest(id: 1, command: 1, data: payload)
    let mid = frame.count / 2

    pair.server.receive(Data(frame[0..<mid]))

    try await confirmation { confirm in
      pair.server.onRequest = { req in
        #expect(req.data == payload)
        confirm()
      }
      pair.server.receive(Data(frame[mid...]))
      try await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  @Test func multipleFramesInSingleReceive() async throws {
    let server = RPC(delegate: CaptureDelegate())

    let frame1 = Messages.encodeRequest(id: 0, command: 1, data: Data([1]))
    let frame2 = Messages.encodeRequest(id: 0, command: 2, data: Data([2]))

    var combined = Data()
    combined.append(frame1)
    combined.append(frame2)

    var commands: [UInt] = []
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

  @Test func streamingRequestSilentlyDiscarded() async throws {
    var body = Data()
    body.append(1)  // type = 1 (request)
    body.append(5)  // id = 5
    body.append(1)  // command = 1
    body.append(1)  // stream = 1 (non-zero)
    body.append(0)  // data length = 0

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

  @Test func streamingEventSilentlyDiscarded() async throws {
    var body = Data()
    body.append(1)  // type = 1 (request)
    body.append(0)  // id = 0 (event)
    body.append(1)  // command = 1
    body.append(1)  // stream = 1 (non-zero)
    body.append(0)  // data length = 0

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

  @Test func unknownMessageTypeDiscarded() async throws {
    let captureDelegate = CaptureDelegate()
    let lock = NSLock()
    var sentAnything = false
    captureDelegate.onSend = { _ in lock.withLock { sentAnything = true } }

    let server = RPC(delegate: captureDelegate)
    server.onRequest = { _ in Issue.record("Should not receive unknown type as request") }
    server.receive(makeRawFrame(Data([99])))
    try await Task.sleep(nanoseconds: 100_000_000)

    lock.withLock { #expect(sentAnything == false) }
  }

  @Test func malformedFrameTriggersOnError() async throws {
    let server = RPC(delegate: CaptureDelegate())

    var body = Data()
    body.append(1)  // type = 1 (request)
    body.append(0xFE)  // start of a varint that needs more bytes — truncated

    try await confirmation { confirm in
      server.onError = { _ in confirm() }
      server.receive(makeRawFrame(body))
      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  @Test func errorErrnoRoundtrip() async throws {
    let pair = RPCPair()
    pair.server.onRequest = { req in req.reject("fail", code: "ENOENT", errno: 42) }

    do {
      _ = try await pair.client.request(1, data: nil)
      Issue.record("Expected error")
    } catch let err as RPCRemoteError {
      #expect(err.message == "fail")
      #expect(err.code == "ENOENT")
      #expect(err.errno == 42)
    }
  }
}
