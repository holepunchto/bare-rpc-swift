import Foundation
import Testing

@testable import BareRPC

class PipeDelegate: RPCDelegate {
  weak var peer: RPC?
  var onRequest: ((IncomingRequest) async throws -> Void)?
  var onEvent: ((IncomingEvent) async -> Void)?
  var onError: ((Error) -> Void)?

  public func rpc(_ rpc: RPC, send data: Data) {
    peer?.receive(data)
  }
  func rpc(_ rpc: RPC, didReceiveRequest request: IncomingRequest) async throws {
    try await onRequest?(request)
  }
  func rpc(_ rpc: RPC, didReceiveEvent event: IncomingEvent) async {
    await onEvent?(event)
  }
  func rpc(_ rpc: RPC, didFailWith error: Error) {
    onError?(error)
  }
}

class CaptureDelegate: RPCDelegate {
  var onSend: ((Data) -> Void)?
  var onRequest: ((IncomingRequest) async throws -> Void)?
  var onEvent: ((IncomingEvent) async -> Void)?
  var onError: ((Error) -> Void)?

  func rpc(_ rpc: RPC, send data: Data) {
    onSend?(data)
  }
  func rpc(_ rpc: RPC, didReceiveRequest request: IncomingRequest) async throws {
    try await onRequest?(request)
  }
  func rpc(_ rpc: RPC, didReceiveEvent event: IncomingEvent) async {
    await onEvent?(event)
  }
  func rpc(_ rpc: RPC, didFailWith error: Error) {
    onError?(error)
  }
}

final class RPCPair {
  let client: RPC
  let server: RPC
  let clientDelegate: PipeDelegate
  let serverDelegate: PipeDelegate

  init() {
    clientDelegate = PipeDelegate()
    serverDelegate = PipeDelegate()
    client = RPC(delegate: clientDelegate)
    server = RPC(delegate: serverDelegate)
    clientDelegate.peer = server
    serverDelegate.peer = client
  }
}

@Suite struct RPCTests {

  @Test func requestResponse() async throws {
    let pair = RPCPair()
    pair.serverDelegate.onRequest = { req in req.reply(req.data) }

    let payload = Data([1, 2, 3])
    let response = try await pair.client.request(42, data: payload)
    #expect(response == payload)
  }

  @Test func requestWithNilResponse() async throws {
    let pair = RPCPair()
    pair.serverDelegate.onRequest = { req in req.reply(nil) }
    let response = try await pair.client.request(1, data: nil)
    #expect(response == nil)
  }

  @Test func requestRejection() async throws {
    let pair = RPCPair()
    pair.serverDelegate.onRequest = { req in req.reject("Oops", code: "ERR", errno: -2) }

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
      pair.serverDelegate.onEvent = { event in
        #expect(event.command == 7)
        #expect(event.data == Data([0xBE, 0xEF]))
        confirm()
      }
      pair.serverDelegate.onRequest = { _ in
        Issue.record("Events should not trigger onRequest")
      }

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
      pair.serverDelegate.onRequest = { req in
        #expect(req.data == payload)
        confirm()
      }
      pair.server.receive(Data(frame[mid...]))
      try await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  @Test func multipleFramesInSingleReceive() async throws {
    let captureDelegate = CaptureDelegate()
    let server = RPC(delegate: captureDelegate)

    let frame1 = Messages.encodeRequest(id: 0, command: 1, data: Data([1]))
    let frame2 = Messages.encodeRequest(id: 0, command: 2, data: Data([2]))

    var combined = Data()
    combined.append(frame1)
    combined.append(frame2)

    var commands: [UInt] = []
    let lock = NSLock()

    try await confirmation(expectedCount: 2) { confirm in
      captureDelegate.onEvent = { event in
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

  @Test func streamingRequestDeliveredWithStream() async throws {
    let pair = RPCPair()

    try await confirmation { confirm in
      pair.serverDelegate.onRequest = { req in
        #expect(req.requestStream != nil)
        #expect(req.command == 1)
        confirm()
      }

      _ = pair.client.createRequestStream(command: 1)
      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  @Test func streamingEventSilentlyDiscarded() async throws {
    var body = Data()
    body.append(1)  // type = 1 (request)
    body.append(0)  // id = 0 (event)
    body.append(1)  // command = 1
    body.append(1)  // stream = 1 (non-zero, no data field on wire)

    let captureDelegate = CaptureDelegate()
    let lock = NSLock()
    var sentAnything = false
    captureDelegate.onSend = { _ in lock.withLock { sentAnything = true } }

    let server = RPC(delegate: captureDelegate)
    captureDelegate.onEvent = { _ in
      Issue.record("Streaming events should be silently discarded")
    }
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
    captureDelegate.onRequest = { _ in
      Issue.record("Should not receive unknown type as request")
    }
    server.receive(makeRawFrame(Data([99])))
    try await Task.sleep(nanoseconds: 100_000_000)

    lock.withLock { #expect(sentAnything == false) }
  }

  @Test func malformedFrameTriggersOnError() async throws {
    let captureDelegate = CaptureDelegate()
    let server = RPC(delegate: captureDelegate)

    var body = Data()
    body.append(1)  // type = 1 (request)
    body.append(0xFE)  // start of a varint that needs more bytes — truncated

    try await confirmation { confirm in
      captureDelegate.onError = { _ in confirm() }
      server.receive(makeRawFrame(body))
      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  @Test func oversizedFrameTriggersFailWithLocalError() async throws {
    let captureDelegate = CaptureDelegate()
    var captured: Error?
    captureDelegate.onError = { captured = $0 }

    let server = RPC(delegate: captureDelegate, maxFrameSize: 100)

    // Forge a 4-byte header claiming a 200-byte body — exceeds the 100-byte cap.
    var header = Data(count: 4)
    let len: UInt32 = 200
    header[0] = UInt8(len & 0xFF)
    header[1] = UInt8((len >> 8) & 0xFF)
    header[2] = UInt8((len >> 16) & 0xFF)
    header[3] = UInt8((len >> 24) & 0xFF)
    server.receive(header)

    guard let err = captured as? RPCLocalError, case .frameTooLarge(let size, let limit) = err
    else {
      Issue.record("Expected frameTooLarge, got: \(String(describing: captured))")
      return
    }
    #expect(size == 204)  // 4-byte header + claimed 200-byte body
    #expect(limit == 100)
  }

  @Test func receiveAfterFailIsNoop() async throws {
    let captureDelegate = CaptureDelegate()
    var errorCount = 0
    captureDelegate.onError = { _ in errorCount += 1 }

    let server = RPC(delegate: captureDelegate, maxFrameSize: 50)

    var header = Data(count: 4)
    let len: UInt32 = 100
    header[0] = UInt8(len & 0xFF)
    header[1] = UInt8((len >> 8) & 0xFF)
    header[2] = UInt8((len >> 16) & 0xFF)
    header[3] = UInt8((len >> 24) & 0xFF)
    server.receive(header)
    #expect(errorCount == 1)

    // Subsequent receive must be ignored — even a well-formed frame.
    server.receive(makeRawFrame(Data([1, 1, 0, 0])))
    #expect(errorCount == 1)
  }

  @Test func errorErrnoRoundtrip() async throws {
    let pair = RPCPair()
    pair.serverDelegate.onRequest = { req in req.reject("fail", code: "ENOENT", errno: 42) }

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
