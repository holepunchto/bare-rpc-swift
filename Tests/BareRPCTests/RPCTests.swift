import Foundation
import Testing

@testable import BareRPC

class PipeDelegate: RPCDelegate {
  weak var peer: RPC?
  var onRequest: ((IncomingRequest) async throws -> Void)?
  var onEvent: ((IncomingEvent) async -> Void)?
  var onError: ((Error) -> Void)?
  private var pendingDelivery: Task<Void, Never> = Task {}

  public func rpc(_ rpc: RPC, send data: Data) {
    let peer = self.peer
    let prev = pendingDelivery
    pendingDelivery = Task {
      await prev.value
      await peer?.receive(data)
    }
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

    await pair.server.receive(Data(frame[0..<mid]))

    try await confirmation { confirm in
      pair.serverDelegate.onRequest = { req in
        #expect(req.data == payload)
        confirm()
      }
      await pair.server.receive(Data(frame[mid...]))
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
      await server.receive(combined)
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

      _ = try pair.client.createRequestStream(command: 1)
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
    await server.receive(makeRawFrame(body))
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
    await server.receive(makeRawFrame(Data([99])))
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
      await server.receive(makeRawFrame(body))
      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  @Test func malformedFramePoisonsConnection() async throws {
    let captureDelegate = CaptureDelegate()
    let rpc = RPC(delegate: captureDelegate)

    async let response: Data? = rpc.request(1, data: nil)
    // Let the request register its continuation before we feed the bad frame.
    try await Task.sleep(nanoseconds: 100_000_000)

    var body = Data()
    body.append(1)  // type = 1 (request)
    body.append(0xFE)  // truncated varint — decode will throw
    await rpc.receive(makeRawFrame(body))

    do {
      _ = try await response
      Issue.record("Expected pending request to throw after malformed frame")
    } catch {
      // Any error from the decode failure is acceptable.
    }

    do {
      _ = try await rpc.request(2, data: nil)
      Issue.record("Expected post-fail request to throw")
    } catch {
      // Any error is acceptable; the gating throws the stored failure error.
    }
  }

  @Test func oversizedFrameTriggersFailWithRPCError() async throws {
    let captureDelegate = CaptureDelegate()
    var captured: Error?
    captureDelegate.onError = { captured = $0 }

    let server = RPC(delegate: captureDelegate, maxFrameSize: 100)

    // Forge a 4-byte header claiming a 200-byte body — exceeds the 100-byte cap.
    let header = makeRawHeader(claimingBodyLen: 200)
    await server.receive(header)

    guard let err = captured as? RPCError, case .frameTooLarge(let size, let limit) = err
    else {
      Issue.record("Expected frameTooLarge, got: \(String(describing: captured))")
      return
    }
    #expect(size == 204)  // 4-byte header + claimed 200-byte body
    #expect(limit == 100)
  }

  @Test func failDrainsPendingRequest() async throws {
    let captureDelegate = CaptureDelegate()
    let rpc = RPC(delegate: captureDelegate, maxFrameSize: 100)

    async let response: Data? = rpc.request(1, data: nil)
    // Let the request register its continuation before we poison the connection.
    try await Task.sleep(nanoseconds: 100_000_000)

    let header = makeRawHeader(claimingBodyLen: 200)
    await rpc.receive(header)

    do {
      _ = try await response
      Issue.record("Expected frameTooLarge")
    } catch let err as RPCError {
      guard case .frameTooLarge(let size, let limit) = err else {
        Issue.record("Expected frameTooLarge, got \(err)")
        return
      }
      #expect(size == 204)
      #expect(limit == 100)
    }
  }

  @Test func failDrainsPendingResponseStream() async throws {
    let captureDelegate = CaptureDelegate()
    let rpc = RPC(delegate: captureDelegate, maxFrameSize: 100)

    async let stream: IncomingStream = rpc.requestWithResponseStream(command: 1)
    // Let the continuation register before we poison the connection.
    try await Task.sleep(nanoseconds: 100_000_000)

    await rpc.receive(makeRawHeader(claimingBodyLen: 200))

    do {
      _ = try await stream
      Issue.record("Expected frameTooLarge")
    } catch let err as RPCError {
      guard case .frameTooLarge(let size, let limit) = err else {
        Issue.record("Expected frameTooLarge, got \(err)")
        return
      }
      #expect(size == 204)
      #expect(limit == 100)
    }
  }

  @Test func frameAtExactlyMaxFrameSizeIsAccepted() async throws {
    let frame = Messages.encodeEvent(command: 1, data: Data([1, 2, 3]))

    let captureDelegate = CaptureDelegate()
    var errors: [Error] = []
    var dispatched = false
    captureDelegate.onError = { errors.append($0) }
    captureDelegate.onEvent = { _ in dispatched = true }

    let server = RPC(delegate: captureDelegate, maxFrameSize: frame.count)
    await server.receive(frame)
    try await Task.sleep(nanoseconds: 100_000_000)

    #expect(errors.isEmpty)
    #expect(dispatched)
  }

  @Test func validFramesAheadOfOversizedFrameStillDispatch() async throws {
    let captureDelegate = CaptureDelegate()
    var dispatchedCommand: UInt?
    var captured: Error?
    captureDelegate.onEvent = { dispatchedCommand = $0.command }
    captureDelegate.onError = { captured = $0 }

    let server = RPC(delegate: captureDelegate, maxFrameSize: 100)
    let valid = Messages.encodeEvent(command: 7, data: Data([1, 2, 3]))
    await server.receive(valid + makeRawHeader(claimingBodyLen: 200))
    try await Task.sleep(nanoseconds: 100_000_000)

    #expect(dispatchedCommand == 7)
    guard let err = captured as? RPCError, case .frameTooLarge = err else {
      Issue.record("Expected frameTooLarge, got: \(String(describing: captured))")
      return
    }
  }

  @Test func receiveAfterFailIsNoop() async throws {
    let captureDelegate = CaptureDelegate()
    var errorCount = 0
    captureDelegate.onError = { _ in errorCount += 1 }

    let server = RPC(delegate: captureDelegate, maxFrameSize: 50)

    let header = makeRawHeader(claimingBodyLen: 100)
    await server.receive(header)
    #expect(errorCount == 1)

    // Subsequent receive must be ignored — even a well-formed frame.
    await server.receive(makeRawFrame(Data([1, 1, 0, 0])))
    #expect(errorCount == 1)
  }

  @Test func requestAfterFailThrowsFailureError() async throws {
    let captureDelegate = CaptureDelegate()
    let rpc = RPC(delegate: captureDelegate, maxFrameSize: 50)

    let header = makeRawHeader(claimingBodyLen: 100)
    await rpc.receive(header)

    do {
      _ = try await rpc.request(1, data: nil)
      Issue.record("Expected frameTooLarge")
    } catch let err as RPCError {
      guard case .frameTooLarge = err else {
        Issue.record("Expected frameTooLarge, got \(err)")
        return
      }
    }
  }

  @Test func requestWithResponseStreamAfterFailThrowsFailureError() async throws {
    let captureDelegate = CaptureDelegate()
    let rpc = RPC(delegate: captureDelegate, maxFrameSize: 50)

    let header = makeRawHeader(claimingBodyLen: 100)
    await rpc.receive(header)

    do {
      _ = try await rpc.requestWithResponseStream(command: 1)
      Issue.record("Expected frameTooLarge")
    } catch let err as RPCError {
      guard case .frameTooLarge = err else {
        Issue.record("Expected frameTooLarge, got \(err)")
        return
      }
    }
  }

  @Test func createRequestStreamAfterFailThrowsFailureError() async throws {
    let captureDelegate = CaptureDelegate()
    let rpc = RPC(delegate: captureDelegate, maxFrameSize: 50)

    let header = makeRawHeader(claimingBodyLen: 100)
    await rpc.receive(header)

    do {
      _ = try rpc.createRequestStream(command: 1)
      Issue.record("Expected frameTooLarge")
    } catch let err as RPCError {
      guard case .frameTooLarge = err else {
        Issue.record("Expected frameTooLarge, got \(err)")
        return
      }
    }
  }

  @Test func eventAfterFailIsSilentlyDropped() async throws {
    let captureDelegate = CaptureDelegate()
    var sendCount = 0
    captureDelegate.onSend = { _ in sendCount += 1 }

    let rpc = RPC(delegate: captureDelegate, maxFrameSize: 50)

    let header = makeRawHeader(claimingBodyLen: 100)
    await rpc.receive(header)

    rpc.event(7, data: Data([0xBE, 0xEF]))
    #expect(sendCount == 0)
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
