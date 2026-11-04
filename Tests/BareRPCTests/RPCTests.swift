import Foundation
import Testing

@testable import BareRPC

@Suite struct RPCTests {

  @Test func requestResponse() async throws {
    let pair = RPCPair()
    pair.serverSide.onRequest = { req in try await req.reply(req.data) }

    let payload = Data([1, 2, 3])
    let response = try await pair.client.request(42, data: payload)
    #expect(response == payload)
  }

  /// Replying with nil puts a zero-length payload on the wire, which the peer
  /// decodes as an empty buffer - the wire cannot tell the two apart.
  @Test func requestWithNilResponse() async throws {
    let pair = RPCPair()
    pair.serverSide.onRequest = { req in try await req.reply(nil) }
    let response = try await pair.client.request(1, data: nil)
    #expect(response == Data())
  }

  @Test func requestRejection() async throws {
    let pair = RPCPair()
    pair.serverSide.onRequest = { req in try await req.reject("Oops", code: "ERR", errno: -2) }

    do {
      _ = try await pair.client.request(1, data: nil)
      Issue.record("Expected error")
    } catch let err as RPCRemoteError {
      #expect(err.message == "Oops")
      #expect(err.code == "ERR")
      #expect(err.errno == -2)
    }
  }

  @Test func throwingRequestHandlerRejectsTheRequest() async throws {
    struct Boom: Error, CustomStringConvertible {
      var description: String { "boom" }
    }

    let pair = RPCPair()
    pair.serverSide.onRequest = { req in
      if req.command == 1 { throw RPCRemoteError(message: "nope", code: "NO", errno: 4) }
      throw Boom()
    }

    do {
      _ = try await pair.client.request(1, data: nil)
      Issue.record("Expected error")
    } catch let err as RPCRemoteError {
      #expect(err.message == "nope")
      #expect(err.code == "NO")
      #expect(err.errno == 4)
    }

    do {
      _ = try await pair.client.request(2, data: nil)
      Issue.record("Expected error")
    } catch let err as RPCRemoteError {
      #expect(err.message == "boom")
      #expect(err.code == "")
      #expect(err.errno == 0)
    }
  }

  @Test func event() async throws {
    let pair = RPCPair()

    try await confirmation { confirm in
      pair.serverSide.onEvent = { event in
        #expect(event.command == 7)
        #expect(event.data == Data([0xBE, 0xEF]))
        confirm()
      }
      pair.serverSide.onRequest = { _ in
        Issue.record("Events should not trigger onRequest")
      }

      await pair.client.event(7, data: Data([0xBE, 0xEF]))
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
      pair.serverSide.onRequest = { req in
        #expect(req.data == payload)
        confirm()
      }
      await pair.server.receive(Data(frame[mid...]))
      try await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  @Test func multipleFramesInSingleReceive() async throws {
    let capture = Capture()
    let server = capture.rpc()

    let frame1 = Messages.encodeRequest(id: 0, command: 1, data: Data([1]))
    let frame2 = Messages.encodeRequest(id: 0, command: 2, data: Data([2]))

    var combined = Data()
    combined.append(frame1)
    combined.append(frame2)

    let commands = Locked<[UInt]>([])

    try await confirmation(expectedCount: 2) { confirm in
      capture.onEvent = { event in
        commands.append(event.command)
        confirm()
      }
      await server.receive(combined)
      try await Task.sleep(nanoseconds: 100_000_000)
    }

    #expect(commands.value.sorted() == [1, 2])
  }

  @Test func streamingRequestDeliveredWithStream() async throws {
    let pair = RPCPair()

    try await confirmation { confirm in
      pair.serverSide.onRequest = { req in
        #expect(req.isStreamed)
        #expect(req.command == 1)
        confirm()
      }

      _ = try await pair.client.createRequestStream(command: 1)
      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  @Test func streamingEventFailsTheConnection() async throws {
    var body = Data()
    body.append(1)  // type = 1 (request)
    body.append(0)  // id = 0 (event)
    body.append(1)  // command = 1
    body.append(1)  // stream = 1 (non-zero, no data field on wire)

    let capture = Capture()

    var captured: Error?
    capture.onError = { captured = $0 }

    let server = capture.rpc()
    capture.onEvent = { _ in
      Issue.record("Streaming events should not be delivered")
    }
    await server.receive(makeRawFrame(body))
    try await Task.sleep(nanoseconds: 100_000_000)

    #expect(capture.sentFrames.isEmpty)
    guard case .invalidMessage = captured as? RPCError else {
      Issue.record("Expected invalidMessage, got \(String(describing: captured))")
      return
    }
  }

  @Test func unknownMessageTypeFailsTheConnection() async throws {
    let capture = Capture()

    var captured: Error?
    capture.onError = { captured = $0 }

    let server = capture.rpc()
    capture.onRequest = { _ in
      Issue.record("Should not receive unknown type as request")
    }
    await server.receive(makeRawFrame(Data([99])))
    try await Task.sleep(nanoseconds: 100_000_000)

    #expect(capture.sentFrames.isEmpty)
    guard case .invalidMessage = captured as? RPCError else {
      Issue.record("Expected invalidMessage, got \(String(describing: captured))")
      return
    }
  }

  @Test func malformedFrameTriggersOnError() async throws {
    let capture = Capture()
    let server = capture.rpc()

    var body = Data()
    body.append(1)  // type = 1 (request)
    body.append(0xFE)  // start of a varint that needs more bytes - truncated

    try await confirmation { confirm in
      capture.onError = { _ in confirm() }
      await server.receive(makeRawFrame(body))
      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  @Test func malformedFramePoisonsConnection() async throws {
    let capture = Capture()
    let rpc = capture.rpc()

    async let response: Data? = rpc.request(1, data: nil)
    // Let the request register its continuation before we feed the bad frame.
    try await Task.sleep(nanoseconds: 100_000_000)

    var body = Data()
    body.append(1)  // type = 1 (request)
    body.append(0xFE)  // truncated varint - decode will throw
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
    let capture = Capture()
    var captured: Error?
    capture.onError = { captured = $0 }

    let server = capture.rpc(maxFrameSize: 100)

    // Forge a 4-byte header claiming a 200-byte body - exceeds the 100-byte cap.
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
    let capture = Capture()
    let rpc = capture.rpc(maxFrameSize: 100)

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
    let capture = Capture()
    let rpc = capture.rpc(maxFrameSize: 100)

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

  @Test func failFailsOpenIncomingStreams() async throws {
    let pair = RPCPair()
    pair.serverSide.onRequest = { req in
      _ = try await req.createResponseStream()
    }

    let incoming = try await pair.client.requestWithResponseStream(command: 1)

    let reading = Task {
      for try await _ in incoming {}
    }

    await pair.client.receive(makeRawHeader(claimingBodyLen: UInt32(RPC.defaultMaxFrameSize)))

    do {
      try await reading.value
      Issue.record("Expected frameTooLarge")
    } catch let err as RPCError {
      guard case .frameTooLarge = err else {
        Issue.record("Expected frameTooLarge, got \(err)")
        return
      }
    }
  }

  @Test func failDestroysOpenOutgoingStreamsAndFailsCorkedWriters() async throws {
    let pair = RPCPair()
    pair.serverSide.onRequest = { req in
      _ = try await req.createRequestStream()
      while true { try await Task.sleep(nanoseconds: 1_000_000_000) }
    }

    let outgoing = try await pair.client.createRequestStream(command: 1)

    try await outgoing.write(Data(count: IncomingStream.defaultHighWaterMark))

    while await !outgoing.isCorked {
      try await Task.sleep(nanoseconds: 5_000_000)
    }

    let writing = Task { try await outgoing.write(Data([0])) }

    await pair.client.receive(makeRawHeader(claimingBodyLen: UInt32(RPC.defaultMaxFrameSize)))

    let tooLarge = RPCError.frameTooLarge(
      size: 4 + RPC.defaultMaxFrameSize, limit: RPC.defaultMaxFrameSize)
    await #expect(throws: tooLarge) { try await writing.value }
    await #expect(throws: tooLarge) { try await outgoing.write(Data([1])) }
    #expect(await outgoing.isEnded)
  }

  @Test func theEndOfTheTransportFailsPendingRequestsWithChannelClosed() async throws {
    let capture = Capture()
    var errors: [Error] = []
    var events = 0
    capture.onError = { errors.append($0) }
    capture.onEvent = { _ in events += 1 }
    let rpc = capture.rpc()

    async let response: Data? = rpc.request(1, data: nil)
    try await Task.sleep(nanoseconds: 100_000_000)

    await capture.input.finish()

    do {
      _ = try await response
      Issue.record("Expected channelClosed")
    } catch let err as RPCError {
      guard case .channelClosed = err else {
        Issue.record("Expected channelClosed, got \(err)")
        return
      }
    }

    await rpc.receive(Messages.encodeEvent(command: 1, data: nil))
    await rpc.close()
    try await Task.sleep(nanoseconds: 50_000_000)

    #expect(errors.count == 1)
    #expect(events == 0)
    try await rpc.wait()
  }

  @Test func aTransportErrorFailsTheSessionWithIt() async throws {
    struct Gone: Error {}

    let capture = Capture()
    let rpc = capture.rpc()

    async let response: Data? = rpc.request(1, data: nil)
    try await Task.sleep(nanoseconds: 100_000_000)

    await capture.input.finish(throwing: Gone())

    do {
      _ = try await response
      Issue.record("Expected Gone")
    } catch {
      #expect(error is Gone)
    }
    await #expect(throws: Gone.self) { try await rpc.wait() }
  }

  @Test func aTransportThatEndsInAFrameFailsWithInvalidMessage() async throws {
    let capture = Capture()
    var captured: Error?
    capture.onError = { captured = $0 }
    let rpc = capture.rpc()

    let frame = Messages.encodeEvent(command: 1, data: Data([1, 2, 3]))
    await rpc.receive(Data(frame.prefix(frame.count - 1)))
    await capture.input.finish()

    guard case .invalidMessage = captured as? RPCError else {
      Issue.record("Expected invalidMessage, got \(String(describing: captured))")
      return
    }
  }

  @Test func aTransportThatThrowsInAFrameFailsWithItsError() async throws {
    let capture = Capture()
    let rpc = capture.rpc()

    let frame = Messages.encodeEvent(command: 1, data: Data([1, 2, 3]))
    await rpc.receive(Data(frame.prefix(frame.count - 1)))
    await capture.input.finish(throwing: POSIXError(.ECONNRESET))

    await #expect(throws: POSIXError(.ECONNRESET)) { try await rpc.wait() }
  }

  @Test func closeFailsOpenIncomingStreamsAndEndsOutgoingStreams() async throws {
    let pair = RPCPair()
    pair.serverSide.onRequest = { req in
      if try await req.createRequestStream() == nil { _ = try await req.createResponseStream() }
    }

    let incoming = try await pair.client.requestWithResponseStream(command: 1)
    let outgoing = try await pair.client.createRequestStream(command: 2)

    await pair.client.close()

    do {
      for try await _ in incoming {}
      Issue.record("Expected channelClosed")
    } catch let err as RPCError {
      guard case .channelClosed = err else {
        Issue.record("Expected channelClosed, got \(err)")
        return
      }
    }
    #expect(await outgoing.isEnded)
  }

  @Test func frameAtExactlyMaxFrameSizeIsAccepted() async throws {
    let frame = Messages.encodeEvent(command: 1, data: Data([1, 2, 3]))

    let capture = Capture()
    var errors: [Error] = []
    var dispatched = false
    capture.onError = { errors.append($0) }
    capture.onEvent = { _ in dispatched = true }

    let server = capture.rpc(maxFrameSize: frame.count)
    await server.receive(frame)
    try await Task.sleep(nanoseconds: 100_000_000)

    #expect(errors.isEmpty)
    #expect(dispatched)
  }

  @Test func validFramesAheadOfOversizedFrameStillDispatch() async throws {
    let capture = Capture()
    var dispatchedCommand: UInt?
    var captured: Error?
    capture.onEvent = { dispatchedCommand = $0.command }
    capture.onError = { captured = $0 }

    let server = capture.rpc(maxFrameSize: 100)
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
    let capture = Capture()
    var errorCount = 0
    capture.onError = { _ in errorCount += 1 }

    let server = capture.rpc(maxFrameSize: 50)

    let header = makeRawHeader(claimingBodyLen: 100)
    await server.receive(header)
    #expect(errorCount == 1)

    // Subsequent receive must be ignored - even a well-formed frame.
    await server.receive(makeRawFrame(Data([1, 1, 0, 0])))
    #expect(errorCount == 1)
  }

  @Test func requestAfterFailThrowsFailureError() async throws {
    let capture = Capture()
    let rpc = capture.rpc(maxFrameSize: 50)

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
    let capture = Capture()
    let rpc = capture.rpc(maxFrameSize: 50)

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
    let capture = Capture()
    let rpc = capture.rpc(maxFrameSize: 50)

    let header = makeRawHeader(claimingBodyLen: 100)
    await rpc.receive(header)

    do {
      _ = try await rpc.createRequestStream(command: 1)
      Issue.record("Expected frameTooLarge")
    } catch let err as RPCError {
      guard case .frameTooLarge = err else {
        Issue.record("Expected frameTooLarge, got \(err)")
        return
      }
    }
  }

  @Test func eventAfterFailIsDropped() async throws {
    let capture = Capture()
    var sendCount = 0
    capture.onSend = { _ in sendCount += 1 }

    let rpc = capture.rpc(maxFrameSize: 50)

    let header = makeRawHeader(claimingBodyLen: 100)
    await rpc.receive(header)

    await rpc.event(7, data: Data([0xBE, 0xEF]))
    #expect(sendCount == 0)
  }

  @Test func errorErrnoRoundtrip() async throws {
    let pair = RPCPair()
    pair.serverSide.onRequest = { req in try await req.reject("fail", code: "ENOENT", errno: 42)
    }

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
