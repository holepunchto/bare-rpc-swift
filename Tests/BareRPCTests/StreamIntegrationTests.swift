import Foundation
import Testing

@testable import BareRPC

@Suite struct StreamIntegrationTests {

  // MARK: - Request stream (initiator writes, responder reads)

  @Test func requestStreamDataFlow() async throws {
    let pair = RPCPair()

    try await confirmation { confirm in
      pair.serverSide.onRequest = { req in
        guard let incoming = try await req.createRequestStream() else {
          Issue.record("Expected request stream")
          return
        }
        #expect(req.command == 42)

        var chunks: [Data] = []
        for try await chunk in incoming {
          chunks.append(chunk)
        }
        #expect(chunks == [Data([1, 2, 3]), Data([4, 5, 6])])
        confirm()
      }

      let stream = try await pair.client.createRequestStream(command: 42)
      try await stream.write(Data([1, 2, 3]))
      try await stream.write(Data([4, 5, 6]))
      await stream.end()

      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  @Test func requestStreamEndSignalsCompletion() async throws {
    let pair = RPCPair()

    try await confirmation { confirm in
      pair.serverSide.onRequest = { req in
        guard let incoming = try await req.createRequestStream() else {
          Issue.record("Expected request stream")
          return
        }

        var count = 0
        for try await _ in incoming {
          count += 1
        }
        #expect(count == 1)
        confirm()
      }

      let stream = try await pair.client.createRequestStream(command: 1)
      try await stream.write(Data([0xFF]))
      await stream.end()

      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  @Test func requestStreamDestroyWithError() async throws {
    let pair = RPCPair()

    try await confirmation { confirm in
      pair.serverSide.onRequest = { req in
        guard let incoming = try await req.createRequestStream() else {
          Issue.record("Expected request stream")
          return
        }

        do {
          for try await _ in incoming {}
          Issue.record("Expected error")
        } catch let err as RPCRemoteError {
          #expect(err.message == "aborted")
          #expect(err.code == "ABORT")
          confirm()
        }
      }

      let stream = try await pair.client.createRequestStream(command: 1)
      // A peer drops frames for a stream that it hasn't opened yet, and the
      // write waits until it has.
      try await stream.write(Data([1]))
      await stream.destroy(error: RPCRemoteError(message: "aborted", code: "ABORT"))

      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  // MARK: - Response stream (responder writes, initiator reads)

  @Test func responseStreamDataFlow() async throws {
    let pair = RPCPair()

    pair.serverSide.onRequest = { req in
      let stream = try await req.createResponseStream()
      try await stream.write(Data([10, 20]))
      try await stream.write(Data([30, 40]))
      await stream.end()
    }

    let incoming = try await pair.client.requestWithResponseStream(command: 42)

    var chunks: [Data] = []
    for try await chunk in incoming {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([10, 20]), Data([30, 40])])
  }

  @Test func responseStreamDestroyWithError() async throws {
    let pair = RPCPair()

    pair.serverSide.onRequest = { req in
      let stream = try await req.createResponseStream()
      await stream.destroy(error: RPCRemoteError(message: "failed", code: "ERR", errno: 1))
    }

    let incoming = try await pair.client.requestWithResponseStream(command: 1)

    do {
      for try await _ in incoming {}
      Issue.record("Expected error")
    } catch let err as RPCRemoteError {
      #expect(err.message == "failed")
      #expect(err.errno == 1)
    }
  }

  @Test func responseStreamForceDestroyByInitiator() async throws {
    let pair = RPCPair()

    pair.serverSide.onRequest = { req in
      #expect(req.command == 42)
      #expect(req.data == Data("foo".utf8))
      let stream = try await req.createResponseStream()
      await stream.destroy()
    }

    let incoming = try await pair.client.requestWithResponseStream(
      command: 42, data: Data("foo".utf8))

    var chunks: [Data] = []
    for try await chunk in incoming {
      chunks.append(chunk)
    }
    #expect(chunks.isEmpty)
  }

  @Test func responseStreamForceDestroyByInitiatee() async throws {
    let pair = RPCPair()
    let serverStream = Locked<OutgoingStream?>(nil)

    pair.serverSide.onRequest = { req in
      #expect(req.command == 42)
      #expect(req.data == Data("foo".utf8))
      serverStream.value = try await req.createResponseStream()
    }

    let incoming = try await pair.client.requestWithResponseStream(
      command: 42, data: Data("foo".utf8))
    await incoming.destroy()

    let observed = try await waitUntil { await serverStream.value?.isEnded == true }
    #expect(observed)
  }

  // MARK: - Empty streams

  @Test func emptyRequestStream() async throws {
    let pair = RPCPair()

    try await confirmation { confirm in
      pair.serverSide.onRequest = { req in
        guard let incoming = try await req.createRequestStream() else {
          Issue.record("Expected request stream")
          return
        }
        var chunks: [Data] = []
        for try await chunk in incoming {
          chunks.append(chunk)
        }
        #expect(chunks.isEmpty)
        confirm()
      }

      let stream = try await pair.client.createRequestStream(command: 1)
      await stream.end()
      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  @Test func emptyResponseStream() async throws {
    let pair = RPCPair()

    pair.serverSide.onRequest = { req in
      let stream = try await req.createResponseStream()
      await stream.end()
    }

    let incoming = try await pair.client.requestWithResponseStream(command: 1)

    var chunks: [Data] = []
    for try await chunk in incoming {
      chunks.append(chunk)
    }
    #expect(chunks.isEmpty)
  }

  // MARK: - Destroy without error

  @Test func requestStreamDestroyWithoutError() async throws {
    let pair = RPCPair()

    try await confirmation { confirm in
      pair.serverSide.onRequest = { req in
        guard let incoming = try await req.createRequestStream() else {
          Issue.record("Expected request stream")
          return
        }
        var chunks: [Data] = []
        for try await chunk in incoming {
          chunks.append(chunk)
        }
        #expect(chunks == [Data([1])])
        confirm()
      }

      let stream = try await pair.client.createRequestStream(command: 1)
      try await stream.write(Data([1]))
      await stream.destroy()
      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  @Test func responseStreamDestroyWithoutError() async throws {
    let pair = RPCPair()

    pair.serverSide.onRequest = { req in
      let stream = try await req.createResponseStream()
      try await stream.write(Data([1]))
      await stream.destroy()
    }

    let incoming = try await pair.client.requestWithResponseStream(command: 1)

    var chunks: [Data] = []
    for try await chunk in incoming {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1])])
  }

  @Test func serverDestroysRequestStreamWithError() async throws {
    let pair = RPCPair()

    pair.serverSide.onRequest = { req in
      guard let incoming = try await req.createRequestStream() else { return }
      await incoming.destroy(error: RPCRemoteError(message: "rejected", code: "ERR_REJECTED"))
    }

    let outgoing = try await pair.client.createRequestStream(command: 1)
    let ended = try await waitUntil { await outgoing.isEnded }
    #expect(ended)
  }

  // MARK: - Request with data alongside response stream

  @Test func responseStreamWithRequestData() async throws {
    let pair = RPCPair()

    pair.serverSide.onRequest = { req in
      #expect(req.data == Data([0xAB]))
      let stream = try await req.createResponseStream()
      try await stream.write(Data([0xCD]))
      await stream.end()
    }

    let incoming = try await pair.client.requestWithResponseStream(
      command: 1, data: Data([0xAB]))

    var chunks: [Data] = []
    for try await chunk in incoming {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([0xCD])])
  }

  // MARK: - Multiple concurrent streams

  @Test func multipleConcurrentRequestStreams() async throws {
    let pair = RPCPair()

    try await confirmation(expectedCount: 2) { confirm in
      pair.serverSide.onRequest = { req in
        guard let incoming = try await req.createRequestStream() else {
          Issue.record("Expected request stream")
          return
        }
        var chunks: [Data] = []
        for try await chunk in incoming {
          chunks.append(chunk)
        }
        // Each stream sends one chunk matching its command
        #expect(chunks.count == 1)
        #expect(chunks[0] == Data([UInt8(req.command)]))
        confirm()
      }

      let stream1 = try await pair.client.createRequestStream(command: 10)
      let stream2 = try await pair.client.createRequestStream(command: 20)
      try await stream1.write(Data([10]))
      try await stream2.write(Data([20]))
      await stream1.end()
      await stream2.end()

      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  // MARK: - Mismatch handling

  @Test func plainReplyToAStreamedReplyIsReadAsOneChunk() async throws {
    let pair = RPCPair()
    pair.serverSide.onRequest = { req in
      try await req.reply(req.command == 1 ? Data([1, 2, 3]) : nil)
    }

    var chunks: [Data] = []
    for try await chunk in try await pair.client.requestWithResponseStream(command: 1) {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1, 2, 3])])

    var empty: [Data] = []
    for try await chunk in try await pair.client.requestWithResponseStream(command: 2) {
      empty.append(chunk)
    }
    #expect(empty.isEmpty)
  }

  @Test func throwingRequestStreamHandlerRejectsTheRequest() async throws {
    let pair = RPCPair()
    pair.serverSide.onRequest = { _ in throw RPCRemoteError(message: "nope", code: "NO") }

    let (_, response) = try await pair.client.streamRequest(command: 1)
    do {
      _ = try await response()
      Issue.record("Expected error")
    } catch let err as RPCRemoteError {
      #expect(err.message == "nope")
      #expect(err.code == "NO")
    }
  }

  @Test func throwingHandlerDestroysAnOpenResponseStream() async throws {
    struct Boom: Error, CustomStringConvertible {
      var description: String { "boom" }
    }

    let pair = RPCPair()
    pair.serverSide.onRequest = { req in
      _ = try await req.createResponseStream()
      throw Boom()
    }

    let (_, incoming) = try await pair.client.createBidirectionalStream(command: 1)
    do {
      for try await _ in incoming {}
      Issue.record("Expected error")
    } catch let err as RPCRemoteError {
      #expect(err.message == "boom")
      #expect(err.code == "")
      #expect(err.errno == 0)
    }
  }

  @Test func errorResponseToResponseStreamPropagatesRemoteError() async throws {
    let pair = RPCPair()
    pair.serverSide.onRequest = { req in
      try await req.reject("boom", code: "ERR_BOOM", errno: -7)
    }

    do {
      _ = try await pair.client.requestWithResponseStream(command: 1)
      Issue.record("Expected error")
    } catch let err as RPCRemoteError {
      #expect(err.message == "boom")
      #expect(err.code == "ERR_BOOM")
      #expect(err.errno == -7)
    }
  }

  @Test func errorResponseToBidirectionalStreamPropagatesRemoteError() async throws {
    let pair = RPCPair()
    pair.serverSide.onRequest = { req in
      try await req.reject("nope", code: "ERR_NOPE", errno: -3)
    }

    do {
      _ = try await pair.client.createBidirectionalStream(command: 1)
      Issue.record("Expected error")
    } catch let err as RPCRemoteError {
      #expect(err.message == "nope")
      #expect(err.code == "ERR_NOPE")
      #expect(err.errno == -3)
    }
  }

  @Test func aStreamReplyToAStreamedRequestFailsItAndClosesAnUnopenedBody() async throws {
    let pair = RPCPair()
    pair.serverSide.onRequest = { req in
      guard req.command == 1 else { return try await req.reply(Data([2])) }
      _ = try await req.createResponseStream()
    }

    let (outgoing, response) = try await pair.client.streamRequest(command: 1)
    let failure = Locked<Error?>(nil)
    Task {
      do { _ = try await response() } catch { failure.value = error }
    }

    #expect(try await waitUntil { failure.value != nil })
    #expect(failure.value as? RPCError == .unexpectedStream)
    #expect(try await waitUntil { await outgoing.isEnded })
    #expect(
      try await waitUntil {
        pair.clientSide.sentStreams.map(\.flags) == [
          StreamFlag.response | StreamFlag.destroy,
          StreamFlag.request | StreamFlag.close | StreamFlag.error,
        ]
      })
    #expect(pair.clientSide.sentStreams.last?.error?.code == "UNEXPECTED_STREAM")
    #expect(try await pair.client.request(2) == Data([2]))
  }

  @Test func aReplyToAStreamedRequestClosesAnUnopenedBody() async throws {
    let pair = RPCPair()
    pair.serverSide.onRequest = { req in try await req.reply(Data([1])) }

    let (outgoing, response) = try await pair.client.streamRequest(command: 1)

    #expect(try await response() == Data([1]))
    #expect(try await waitUntil { await outgoing.isEnded })
    #expect(
      try await waitUntil {
        pair.clientSide.sentStreams.map(\.flags) == [StreamFlag.request | StreamFlag.close]
      })
  }

  @Test func aRejectionOfAStreamedRequestClosesAnUnopenedBodyWithItsError() async throws {
    let pair = RPCPair()
    let rejection = RPCRemoteError(message: "no", code: "NOPE", errno: 1)
    pair.serverSide.onRequest = { req in
      try await req.reject(rejection.message, code: rejection.code, errno: rejection.errno)
    }

    let (outgoing, response) = try await pair.client.streamRequest(command: 1)

    await #expect(throws: rejection) { try await response() }
    #expect(try await waitUntil { await outgoing.isEnded })
    #expect(
      try await waitUntil {
        pair.clientSide.sentStreams.map(\.flags) == [
          StreamFlag.request | StreamFlag.close | StreamFlag.error
        ]
      })
    #expect(pair.clientSide.sentStreams.last?.error == rejection)
  }

  @Test func aStreamReplyToAPlainRequestFailsItAndReleasesThePeer() async throws {
    let pair = RPCPair()
    let serverStream = Locked<OutgoingStream?>(nil)
    let released = Locked(false)
    pair.serverSide.onRequest = { req in
      guard req.command == 1 else { return try await req.reply(Data([2])) }
      let stream = try await req.createResponseStream()
      serverStream.value = stream
      try await stream.write(Data([1]))
      released.value = true
    }

    await #expect(throws: RPCError.unexpectedStream) { try await pair.client.request(1) }

    #expect(try await waitUntil { released.value })
    #expect(await serverStream.value?.isEnded == true)
    #expect(try await pair.client.request(2) == Data([2]))
  }

  // MARK: - Backpressure

  @Test func corkOnlyAtHighWaterMarkInBytes() async throws {
    let pair = RPCPair()
    pair.serverSide.onRequest = { req in _ = try await req.createRequestStream() }

    let outgoing = try await pair.client.createRequestStream(command: 1)

    for i in 0..<16 {
      try await outgoing.write(Data([UInt8(i)]))
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(await !outgoing.isCorked)

    try await outgoing.write(Data(count: IncomingStream.defaultHighWaterMark - 17))
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(await !outgoing.isCorked)

    try await outgoing.write(Data([0]))
    let paused = try await waitUntil { await outgoing.isCorked }
    #expect(paused)
  }

  @Test func streamsOfRequestsWithTheSameIdOnBothSidesStayApart() async throws {
    let pair = RPCPair()
    let serverResponse = Locked<OutgoingStream?>(nil)
    let clientRequestBody = Locked<IncomingStream?>(nil)

    pair.serverSide.onRequest = { req in
      serverResponse.value = try await req.createResponseStream()
    }
    pair.clientSide.onRequest = { req in
      clientRequestBody.value = try await req.createRequestStream()
    }

    let response = try await pair.client.requestWithResponseStream(command: 1)
    let request = try await pair.server.createRequestStream(command: 2)

    #expect(response.requestId == request.requestId)

    let opened = try await waitUntil {
      serverResponse.value != nil && clientRequestBody.value != nil
    }
    #expect(opened)

    try await serverResponse.value!.write(Data("response".utf8))
    await serverResponse.value!.end()
    try await request.write(Data("request".utf8))
    await request.end()

    var responseChunks: [Data] = []
    for try await chunk in response { responseChunks.append(chunk) }

    var requestChunks: [Data] = []
    for try await chunk in clientRequestBody.value! { requestChunks.append(chunk) }

    #expect(responseChunks == [Data("response".utf8)])
    #expect(requestChunks == [Data("request".utf8)])
  }

  @Test func peerDestroyReleasesACorkedWriter() async throws {
    let pair = RPCPair()
    let serverStream = Locked<IncomingStream?>(nil)

    pair.serverSide.onRequest = { req in
      serverStream.value = try await req.createRequestStream()
    }

    let outgoing = try await pair.client.createRequestStream(command: 1)
    try await outgoing.write(Data(count: IncomingStream.defaultHighWaterMark))

    let paused = try await waitUntil { await outgoing.isCorked && serverStream.value != nil }
    #expect(paused)

    let writing = Task { try await outgoing.write(Data([16])) }

    await serverStream.value!.destroy()

    try await writing.value
    #expect(try await waitUntil { await outgoing.isEnded })
  }

  @Test func pauseAndResumeRoundTrip() async throws {
    let pair = RPCPair()
    let serverStream = Locked<IncomingStream?>(nil)

    pair.serverSide.onRequest = { req in
      serverStream.value = try await req.createRequestStream()
    }

    let outgoing = try await pair.client.createRequestStream(command: 1)
    let chunk = Data(count: IncomingStream.defaultHighWaterMark / 4)
    for _ in 0..<4 {
      try await outgoing.write(chunk)
    }

    let paused = try await waitUntil { await outgoing.isCorked && serverStream.value != nil }
    #expect(paused)

    // Reading one chunk leaves fewer than highWaterMark bytes buffered.
    let iter = serverStream.value!.makeAsyncIterator()
    _ = try await iter.next()

    let resumed = try await waitUntil { await !outgoing.isCorked }
    #expect(resumed)
  }
}
