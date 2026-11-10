import Foundation
import Testing

@testable import BareRPC

private let cancel = RPCRemoteError(message: "Gave up", code: "GAVE_UP", errno: 3)

@Suite(.timeLimit(.minutes(1))) struct CancellationTests {

  @Test func cancellingTheTaskCancelsTheHandler() async throws {
    let pair = RPCPair()
    let started = Locked(false)
    let observed = Locked<RPCRemoteError?>(nil)
    let returned = Locked(false)

    pair.serverSide.onRequest = { req in
      started.value = true
      do {
        try await Task.sleep(nanoseconds: 10_000_000_000)
      } catch {
        observed.value = req.cancellationError
        try await req.reply(Data("late".utf8))
        returned.value = true
      }
    }

    let task = Task { try await pair.client.request(1) }
    #expect(try await waitUntil { started.value })
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await waitUntil { returned.value })
    #expect(observed.value?.code == "CANCELLED")
    await pair.server.event(9)
    #expect(try await waitUntil { !pair.serverSide.sentRequests.isEmpty })
    #expect(pair.serverSide.sentResponses.isEmpty)
    #expect(await pair.server.trackedStateCount == 0)
  }

  @Test func timeoutCancelsTheRequest() async throws {
    let pair = RPCPair()
    let observed = Locked<RPCRemoteError?>(nil)

    pair.serverSide.onRequest = { req in
      try? await Task.sleep(nanoseconds: 10_000_000_000)
      observed.value = req.cancellationError
    }

    await #expect(throws: RPCError.timeout) {
      try await pair.client.request(1, timeout: 0.05)
    }
    #expect(try await waitUntil { observed.value != nil })
    #expect(observed.value?.code == "TIMEOUT")
  }

  @Test func aRequestOfACancelledTaskIsNeverSent() async throws {
    let pair = RPCPair()

    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await pair.client.request(1)
    }

    await #expect(throws: CancellationError.self) { try await task.value }
    await pair.client.event(9)
    #expect(try await waitUntil { !pair.clientSide.sentRequests.isEmpty })
    #expect(pair.clientSide.sentFrames.count == 1)
  }

  @Test func cancellingAStreamedRequestFailsTheStreamsOfBothEnds() async throws {
    let pair = RPCPair()
    let received = Locked<Error?>(nil)

    pair.serverSide.onRequest = { req in
      let body = try await req.createRequestStream()!
      do {
        for try await _ in body {}
      } catch {
        received.value = error
      }
    }

    let task = Task { try await pair.client.createBidirectionalStream(command: 1) }
    #expect(try await waitUntil { await pair.server.trackedStateCount > 0 })
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await waitUntil { received.value != nil })
    #expect((received.value as? RPCRemoteError)?.code == "CANCELLED")
    #expect(await pair.client.trackedStateCount == 0)
    #expect(await pair.server.trackedStateCount == 0)
  }

  @Test func aCancelledRequestIsNotAnswered() async throws {
    let peer = Capture()
    let rpc = peer.rpc()
    let streams = Locked<[OutgoingStream]>([])
    let returned = Locked(0)

    peer.onRequest = { req in
      try? await Task.sleep(nanoseconds: 10_000_000_000)
      if req.command == 1 { try await req.reply(nil) }
      if req.command == 2 { streams.append(try await req.createResponseStream()) }
      if req.command == 3 { try await req.reject("Nope") }
      returned.withLock { $0 += 1 }
    }

    for id: UInt in 1...3 {
      await rpc.receive(Messages.encodeRequest(id: id, command: id, data: nil))
      await rpc.receive(Messages.encodeCancel(id: id, error: cancel))
    }

    #expect(try await waitUntil { returned.value == 3 })
    let stream = try #require(streams.value.first)
    try await stream.write(Data([1]))
    #expect(await stream.isEnded)
    await rpc.event(9)
    #expect(try await waitUntil { !peer.sentRequests.isEmpty })
    #expect(peer.sentFrames.count == 1)
    #expect(await rpc.trackedStateCount == 0)
  }

  @Test func aCancelAfterTheReplyAbortsABodyOpenedLater() async throws {
    let peer = Capture()
    let rpc = peer.rpc()
    let replied = Locked(false)
    let observed = Locked<RPCRemoteError?>(nil)
    let received = Locked<Error?>(nil)

    peer.onRequest = { req in
      try await req.reply(nil)
      replied.value = true
      try? await Task.sleep(nanoseconds: 10_000_000_000)
      observed.value = req.cancellationError
      let body = try await req.createRequestStream()!
      do {
        for try await _ in body {}
      } catch {
        received.value = error
      }
    }

    await rpc.receive(Messages.encodeRequest(id: 1, command: 1, stream: StreamFlag.open, data: nil))
    #expect(try await waitUntil { replied.value })
    await rpc.receive(Messages.encodeCancel(id: 1, error: cancel))

    #expect(try await waitUntil { received.value != nil })
    #expect(observed.value == cancel)
    #expect((received.value as? RPCRemoteError) == cancel)
    #expect(peer.sentStreams.isEmpty)
    #expect(await rpc.trackedStateCount == 0)
  }

  @Test func aCancelDropsAnOpenReplyStream() async throws {
    let peer = Capture()
    let rpc = peer.rpc()
    let stream = Locked<OutgoingStream?>(nil)
    let observed = Locked<RPCRemoteError?>(nil)

    peer.onRequest = { req in
      stream.value = try await req.createResponseStream()
      try? await Task.sleep(nanoseconds: 10_000_000_000)
      observed.value = req.cancellationError
    }

    await rpc.receive(Messages.encodeRequest(id: 1, command: 1, data: nil))
    #expect(try await waitUntil { stream.value != nil })
    await rpc.receive(Messages.encodeCancel(id: 1, error: cancel))

    #expect(try await waitUntil { observed.value != nil })
    #expect(observed.value == cancel)
    #expect(try await #require(stream.value).isEnded)
    #expect(await rpc.trackedStateCount == 0)
    #expect(peer.sentStreams.isEmpty)
  }

  @Test func theAnswerOfACancelledRequestIsNotSentForARequestThatReusesItsId() async throws {
    let peer = Capture()
    let rpc = peer.rpc()
    let gate = Locked<CheckedContinuation<Void, Never>?>(nil)
    let staleAnswered = Locked(false)

    peer.onRequest = { req in
      if req.command == 1 {
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        await withCheckedContinuation { gate.value = $0 }
        try await req.reply(Data("stale".utf8))
        staleAnswered.value = true
      } else {
        _ = try await waitUntil { staleAnswered.value }
        try await req.reply(Data("fresh".utf8))
      }
    }

    await rpc.receive(Messages.encodeRequest(id: 1, command: 1, data: nil))
    await rpc.receive(Messages.encodeCancel(id: 1, error: cancel))
    #expect(try await waitUntil { gate.value != nil })
    await rpc.receive(Messages.encodeRequest(id: 1, command: 2, data: nil))
    try #require(gate.value).resume()

    #expect(try await waitUntil { peer.sentResponses.count == 1 })
    guard case .success(let data) = peer.sentResponses.first?.result else {
      Issue.record("Expected a reply")
      return
    }
    #expect(data == Data("fresh".utf8))
    #expect(await rpc.trackedStateCount == 0)
  }

  @Test func readingABufferedBodyAfterACancelSendsNoResume() async throws {
    let peer = Capture()
    let rpc = peer.rpc()
    let gate = Locked<CheckedContinuation<Void, Never>?>(nil)
    let read = Locked(false)

    peer.onRequest = { req in
      let body = try await req.createRequestStream()!
      await withCheckedContinuation { gate.value = $0 }
      do {
        for try await _ in body {}
      } catch {}
      read.value = true
    }

    await rpc.receive(Messages.encodeRequest(id: 1, command: 1, stream: StreamFlag.open, data: nil))
    #expect(try await waitUntil { gate.value != nil })
    await rpc.receive(
      Messages.encodeStream(
        id: 1, flags: StreamFlag.request | StreamFlag.data,
        data: Data(count: IncomingStream.defaultHighWaterMark)))
    await rpc.receive(Messages.encodeCancel(id: 1, error: cancel))
    try #require(gate.value).resume()

    #expect(try await waitUntil { read.value })
    await rpc.event(9)
    #expect(try await waitUntil { !peer.sentRequests.isEmpty })
    #expect(peer.sentStreams.contains { $0.flags & StreamFlag.pause != 0 })
    #expect(!peer.sentStreams.contains { $0.flags & StreamFlag.resume != 0 })
  }

  @Test func cancellingARequestWithAResponseStreamSendsACancel() async throws {
    let peer = Capture()
    let rpc = peer.rpc()

    let task = Task { try await rpc.requestWithResponseStream(command: 1) }
    #expect(try await waitUntil { peer.sentFrames.count == 2 })
    task.cancel()

    #expect(try await waitUntil { sentCancels(peer).count == 1 })
    #expect(sentCancels(peer).first?.id == 1)
    #expect(sentCancels(peer).first?.error.code == "CANCELLED")
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await rpc.trackedStateCount == 0)
  }

  @Test func cancellingTheResponseOfAStreamedRequestSendsACancel() async throws {
    let peer = Capture()
    let rpc = peer.rpc()
    let (outgoing, response) = try await rpc.streamRequest(command: 1)

    let task = Task { try await response() }
    #expect(try await waitUntil { peer.sentFrames.count == 1 })
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await waitUntil { sentCancels(peer).count == 1 })
    #expect(sentCancels(peer).first?.error.code == "CANCELLED")
    #expect(await outgoing.isEnded)
    #expect(await rpc.trackedStateCount == 0)
  }

  @Test func cancellingAfterTheAnswerSendsNothing() async throws {
    let peer = Capture()
    let rpc = peer.rpc()
    let (_, response) = try await rpc.streamRequest(command: 1)
    await rpc.receive(Messages.encodeResponse(id: 1, data: Data([1])))

    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await response()
    }
    #expect(try await task.value == Data([1]))
    await rpc.event(9)
    #expect(try await waitUntil { !peer.sentRequests.isEmpty })

    #expect(sentCancels(peer).isEmpty)
  }

  @Test func aRequestAnsweredWithinItsTimeoutSendsNoCancel() async throws {
    let peer = Capture()
    let rpc = peer.rpc()

    let reply = Task { try await rpc.request(1, timeout: 0.05) }
    #expect(try await waitUntil { peer.sentRequests.count == 1 })
    await rpc.receive(Messages.encodeResponse(id: 1, data: Data([1])))
    #expect(try await reply.value == Data([1]))

    try await Task.sleep(nanoseconds: 100_000_000)
    await rpc.event(9)
    #expect(try await waitUntil { peer.sentRequests.count == 2 })
    #expect(sentCancels(peer).isEmpty)
  }

  @Test func cancellingTheReaderOfAReplyStreamCancelsTheRequest() async throws {
    let peer = Capture()
    let rpc = peer.rpc()
    let chunks = Locked<[Data]>([])
    let failure = Locked<Error?>(nil)

    let task = Task {
      do {
        let stream = try await rpc.requestWithResponseStream(command: 1)
        for try await chunk in stream { chunks.append(chunk) }
      } catch {
        failure.value = error
      }
    }
    #expect(try await waitUntil { peer.sentFrames.count == 2 })
    await rpc.receive(Messages.encodeResponse(id: 1, stream: StreamFlag.open, data: nil))
    await rpc.receive(
      Messages.encodeStream(id: 1, flags: StreamFlag.response | StreamFlag.data, data: Data([1])))
    #expect(try await waitUntil { chunks.value.count == 1 })
    task.cancel()

    try #require(try await waitUntil { failure.value != nil })
    #expect(failure.value is CancellationError)
    #expect(try await waitUntil { sentCancels(peer).count == 1 })
    #expect(sentCancels(peer).first?.id == 1)
    #expect(sentCancels(peer).first?.error.code == "CANCELLED")
    await rpc.event(9)
    #expect(try await waitUntil { peer.sentRequests.count == 2 })
    #expect(peer.sentStreams.count == 1)
    #expect(await rpc.trackedStateCount == 0)
  }

  @Test func cancellingTheReaderOfABidirectionalStreamDropsItsBody() async throws {
    let peer = Capture()
    let rpc = peer.rpc()

    let opened = Task { try await rpc.createBidirectionalStream(command: 1) }
    #expect(try await waitUntil { peer.sentFrames.count == 2 })
    await rpc.receive(Messages.encodeResponse(id: 1, stream: StreamFlag.open, data: nil))
    let (outgoing, incoming) = try await opened.value

    let failure = Locked<Error?>(nil)
    let task = Task {
      do {
        for try await _ in incoming {}
      } catch {
        failure.value = error
      }
    }
    task.cancel()

    try #require(try await waitUntil { failure.value != nil })
    #expect(failure.value is CancellationError)
    #expect(try await waitUntil { sentCancels(peer).count == 1 })
    try #require(await outgoing.isEnded)
    await #expect(throws: CancellationError.self) { try await outgoing.write(Data([1])) }
    await rpc.event(9)
    #expect(try await waitUntil { peer.sentRequests.count == 2 })
    #expect(peer.sentStreams.count == 1)
    #expect(await rpc.trackedStateCount == 0)
  }

  @Test func cancellingTheReaderOfAnEndedReplyStreamSendsNothing() async throws {
    let peer = Capture()
    let rpc = peer.rpc()

    let opened = Task { try await rpc.requestWithResponseStream(command: 1) }
    #expect(try await waitUntil { peer.sentFrames.count == 2 })
    await rpc.receive(Messages.encodeResponse(id: 1, stream: StreamFlag.open, data: nil))
    let stream = try await opened.value
    await rpc.receive(
      Messages.encodeStream(id: 1, flags: StreamFlag.response | StreamFlag.data, data: Data([1])))
    await rpc.receive(Messages.encodeStream(id: 1, flags: StreamFlag.response | StreamFlag.end))

    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      var chunks: [Data] = []
      for try await chunk in stream { chunks.append(chunk) }
      return chunks
    }
    #expect(try await task.value == [Data([1])])
    await rpc.event(9)
    #expect(try await waitUntil { peer.sentRequests.count == 2 })
    #expect(sentCancels(peer).isEmpty)
  }

  @Test func cancellingTheReaderOfARequestBodyOnlyStopsTheRead() async throws {
    let peer = Capture()
    let rpc = peer.rpc()
    let body = Locked<IncomingStream?>(nil)

    peer.onRequest = { req in body.value = try await req.createRequestStream() }

    await rpc.receive(Messages.encodeRequest(id: 1, command: 1, stream: StreamFlag.open, data: nil))
    #expect(try await waitUntil { body.value != nil })
    let stream = try #require(body.value)

    let failure = Locked<Error?>(nil)
    let reader = Task {
      do {
        for try await _ in stream {}
      } catch {
        failure.value = error
      }
    }
    reader.cancel()
    try #require(try await waitUntil { failure.value != nil })
    #expect(failure.value is CancellationError)

    await rpc.receive(
      Messages.encodeStream(id: 1, flags: StreamFlag.request | StreamFlag.data, data: Data([1])))
    await rpc.receive(Messages.encodeStream(id: 1, flags: StreamFlag.request | StreamFlag.end))
    var chunks: [Data] = []
    for try await chunk in stream { chunks.append(chunk) }
    #expect(chunks == [Data([1])])
    await rpc.event(9)
    #expect(try await waitUntil { !peer.sentRequests.isEmpty })
    #expect(sentCancels(peer).isEmpty)
    #expect(peer.sentStreams.count == 1)
  }

  @Test func framesAfterOneThatFailsTheSessionAreNotHandled() async throws {
    let peer = Capture()
    let rpc = peer.rpc()
    let started = Locked(false)
    let cancelled = Locked(false)

    peer.onRequest = { _ in
      started.value = true
      try? await Task.sleep(nanoseconds: 10_000_000_000)
      cancelled.value = Task.isCancelled
    }

    await rpc.receive(
      Messages.encodeCancel(id: 0, error: cancel)
        + Messages.encodeRequest(id: 1, command: 1, data: nil))
    await #expect(throws: RPCError.self) { try await rpc.wait() }

    if try await waitUntil({ started.value }) {
      #expect(try await waitUntil { cancelled.value })
    }
  }

  @Test func aHandlerOfARequestWhoseIdWasReusedCannotOpenItsBody() async throws {
    let peer = Capture()
    let rpc = peer.rpc()
    let gate = Locked<CheckedContinuation<Void, Never>?>(nil)
    let staleError = Locked<Error?>(nil)
    let fresh = Locked<IncomingStream?>(nil)

    peer.onRequest = { req in
      if req.command == 1 {
        try await req.reply(nil)
        await withCheckedContinuation { gate.value = $0 }
        let body = try await req.createRequestStream()!
        do {
          for try await _ in body {}
        } catch {
          staleError.value = error
        }
      } else {
        fresh.value = try await req.createRequestStream()
      }
    }

    await rpc.receive(Messages.encodeRequest(id: 1, command: 1, stream: StreamFlag.open, data: nil))
    #expect(try await waitUntil { gate.value != nil })
    await rpc.receive(Messages.encodeRequest(id: 1, command: 2, stream: StreamFlag.open, data: nil))
    #expect(try await waitUntil { fresh.value != nil })
    try #require(gate.value).resume()

    try #require(try await waitUntil { staleError.value != nil })
    await rpc.receive(
      Messages.encodeStream(id: 1, flags: StreamFlag.request | StreamFlag.data, data: Data([1])))
    await rpc.receive(Messages.encodeStream(id: 1, flags: StreamFlag.request | StreamFlag.end))
    var chunks: [Data] = []
    for try await chunk in try #require(fresh.value) { chunks.append(chunk) }
    #expect(chunks == [Data([1])])
    #expect(peer.sentStreams.filter { $0.flags & StreamFlag.open != 0 }.count == 1)
  }

  @Test func aCancelHasTheBytesOfLibrpc() throws {
    let error = RPCRemoteError(message: "Cancelled", code: "CANCELLED", errno: -1)
    let frame =
      Data([0x17, 0x00, 0x00, 0x00, 0x04, 0x01, 0x09]) + Data("Cancelled".utf8) + Data([0x09])
      + Data("CANCELLED".utf8) + Data([0x01])
    #expect(Messages.encodeCancel(id: 1, error: error) == frame)

    guard case .cancel(let msg) = try Messages.decodeFrame(frame) else {
      Issue.record("Expected a cancel")
      return
    }
    #expect(msg.id == 1)
    #expect(msg.error == error)
  }

  @Test func aRequestWithAnInfiniteTimeoutIsAnswered() async throws {
    let pair = RPCPair()
    pair.serverSide.onRequest = { req in try await req.reply(Data([1])) }

    #expect(try await pair.client.request(1, timeout: .infinity) == Data([1]))
  }

  @Test func aCancelForAnUnknownRequestIsIgnored() async throws {
    let peer = Capture()
    let rpc = peer.rpc()

    await rpc.receive(Messages.encodeCancel(id: 7, error: cancel))
    let reply = Task { try await rpc.request(1) }
    await rpc.receive(Messages.encodeResponse(id: 1, data: Data([1])))

    #expect(try await reply.value == Data([1]))
  }

  @Test func closingTheSessionCancelsTheEventHandler() async throws {
    let pair = RPCPair()
    let started = Locked(false)
    let cancelled = Locked(false)

    pair.serverSide.onEvent = { _ in
      started.value = true
      try? await Task.sleep(nanoseconds: 10_000_000_000)
      cancelled.value = Task.isCancelled
    }

    await pair.client.event(1)
    #expect(try await waitUntil { started.value })
    await pair.server.close()

    #expect(try await waitUntil { cancelled.value })
  }

  @Test func aHandlerThatClosesTheSessionIsCancelledOnceCloseReturns() async throws {
    let pair = RPCPair()
    let steps = Locked<[String]>([])

    pair.serverSide.onRequest = { _ in
      await pair.server.close()
      steps.append("closed")
      try? await Task.sleep(nanoseconds: 10_000_000_000)
      steps.append(Task.isCancelled ? "cancelled" : "not cancelled")
    }

    let request = Task { try await pair.client.request(1) }
    #expect(try await waitUntil { steps.value.count == 2 })
    #expect(steps.value == ["closed", "cancelled"])
    request.cancel()
  }

  @Test func closingTheSessionCancelsAHandlerWhoseIdWasReused() async throws {
    let peer = Capture()
    let rpc = peer.rpc()
    let replied = Locked(false)
    let cancelled = Locked(false)

    peer.onRequest = { req in
      if req.command == 1 {
        try await req.reply(nil)
        replied.value = true
      }
      try? await Task.sleep(nanoseconds: 10_000_000_000)
      if req.command == 1 { cancelled.value = Task.isCancelled }
    }

    await rpc.receive(Messages.encodeRequest(id: 1, command: 1, data: nil))
    #expect(try await waitUntil { replied.value })
    await rpc.receive(Messages.encodeRequest(id: 1, command: 2, data: nil))
    await rpc.close()

    #expect(try await waitUntil { cancelled.value })
  }

  @Test func closingTheSessionCancelsTheHandler() async throws {
    let pair = RPCPair()
    let started = Locked(false)
    let cancelled = Locked(false)

    pair.serverSide.onRequest = { _ in
      started.value = true
      try? await Task.sleep(nanoseconds: 10_000_000_000)
      cancelled.value = Task.isCancelled
    }

    let request = Task { try await pair.client.request(1) }
    #expect(try await waitUntil { started.value })
    await pair.server.close()

    #expect(try await waitUntil { cancelled.value })
    request.cancel()
  }
}

private func sentCancels(_ peer: Capture) -> [CancelMessage] {
  peer.sentMessages.compactMap {
    guard case .cancel(let msg) = $0 else { return nil }
    return msg
  }
}
