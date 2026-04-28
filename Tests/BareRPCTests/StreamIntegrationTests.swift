import Foundation
import Testing

@testable import BareRPC

private final class StreamHolder<Stream> {
  var value: Stream?
}

private func waitUntil(
  timeoutNs: UInt64 = 1_000_000_000,
  stepNs: UInt64 = 5_000_000,
  _ condition: () -> Bool
) async throws -> Bool {
  var elapsed: UInt64 = 0
  while elapsed < timeoutNs {
    if condition() { return true }
    try await Task.sleep(nanoseconds: stepNs)
    elapsed += stepNs
  }
  return condition()
}

@Suite struct StreamIntegrationTests {

  // MARK: - Request stream (initiator writes, responder reads)

  @Test func requestStreamDataFlow() async throws {
    let pair = RPCPair()

    try await confirmation { confirm in
      pair.serverDelegate.onRequest = { req in
        guard let incoming = req.requestStream else {
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

      let stream = pair.client.createRequestStream(command: 42)
      await stream.write(Data([1, 2, 3]))
      await stream.write(Data([4, 5, 6]))
      stream.end()

      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  @Test func requestStreamEndSignalsCompletion() async throws {
    let pair = RPCPair()

    try await confirmation { confirm in
      pair.serverDelegate.onRequest = { req in
        guard let incoming = req.requestStream else {
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

      let stream = pair.client.createRequestStream(command: 1)
      await stream.write(Data([0xFF]))
      stream.end()

      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  @Test func requestStreamDestroyWithError() async throws {
    let pair = RPCPair()

    try await confirmation { confirm in
      pair.serverDelegate.onRequest = { req in
        guard let incoming = req.requestStream else {
          Issue.record("Expected request stream")
          return
        }

        do {
          for try await _ in incoming {}
          Issue.record("Expected error")
        } catch let err as RPCRemoteError {
          #expect(err.message == "aborted")
          confirm()
        }
      }

      let stream = pair.client.createRequestStream(command: 1)
      stream.destroy(error: RPCRemoteError(message: "aborted", code: "ABORT"))

      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  // MARK: - Response stream (responder writes, initiator reads)

  @Test func responseStreamDataFlow() async throws {
    let pair = RPCPair()

    pair.serverDelegate.onRequest = { req in
      let stream = req.createResponseStream()!
      await stream.write(Data([10, 20]))
      await stream.write(Data([30, 40]))
      stream.end()
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

    pair.serverDelegate.onRequest = { req in
      let stream = req.createResponseStream()!
      stream.destroy(error: RPCRemoteError(message: "failed", code: "ERR", errno: 1))
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

    pair.serverDelegate.onRequest = { req in
      #expect(req.command == 42)
      #expect(req.data == Data("foo".utf8))
      let stream = req.createResponseStream()!
      stream.destroy()
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
    let serverStream = StreamHolder<OutgoingStream>()

    pair.serverDelegate.onRequest = { req in
      #expect(req.command == 42)
      #expect(req.data == Data("foo".utf8))
      serverStream.value = req.createResponseStream()!
    }

    let incoming = try await pair.client.requestWithResponseStream(
      command: 42, data: Data("foo".utf8))
    incoming.destroy()

    let observed = try await waitUntil { serverStream.value?.ended == true }
    #expect(observed)
  }

  // MARK: - Empty streams

  @Test func emptyRequestStream() async throws {
    let pair = RPCPair()

    try await confirmation { confirm in
      pair.serverDelegate.onRequest = { req in
        guard let incoming = req.requestStream else {
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

      let stream = pair.client.createRequestStream(command: 1)
      stream.end()
      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  @Test func emptyResponseStream() async throws {
    let pair = RPCPair()

    pair.serverDelegate.onRequest = { req in
      let stream = req.createResponseStream()!
      stream.end()
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
      pair.serverDelegate.onRequest = { req in
        guard let incoming = req.requestStream else {
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

      let stream = pair.client.createRequestStream(command: 1)
      await stream.write(Data([1]))
      stream.destroy()
      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  @Test func responseStreamDestroyWithoutError() async throws {
    let pair = RPCPair()

    pair.serverDelegate.onRequest = { req in
      let stream = req.createResponseStream()!
      await stream.write(Data([1]))
      stream.destroy()
    }

    let incoming = try await pair.client.requestWithResponseStream(command: 1)

    var chunks: [Data] = []
    for try await chunk in incoming {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1])])
  }

  // MARK: - Request with data alongside response stream

  @Test func responseStreamWithRequestData() async throws {
    let pair = RPCPair()

    pair.serverDelegate.onRequest = { req in
      #expect(req.data == Data([0xAB]))
      let stream = req.createResponseStream()!
      await stream.write(Data([0xCD]))
      stream.end()
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
      pair.serverDelegate.onRequest = { req in
        guard let incoming = req.requestStream else {
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

      let stream1 = pair.client.createRequestStream(command: 10)
      let stream2 = pair.client.createRequestStream(command: 20)
      await stream1.write(Data([10]))
      await stream2.write(Data([20]))
      stream1.end()
      stream2.end()

      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  // MARK: - Mismatch handling

  @Test func normalResponseFailsPendingStreamContinuation() async throws {
    let pair = RPCPair()
    pair.serverDelegate.onRequest = { req in req.reply(Data([1, 2, 3])) }

    do {
      _ = try await pair.client.requestWithResponseStream(command: 1)
      Issue.record("Expected error")
    } catch let err as RPCRemoteError {
      #expect(err.code == "ERR_NOT_STREAM")
    }
  }

  @Test func streamResponseFailsPendingNormalContinuation() async throws {
    let pair = RPCPair()
    pair.serverDelegate.onRequest = { req in
      let stream = req.createResponseStream()!
      stream.end()
    }

    do {
      _ = try await pair.client.request(1)
      Issue.record("Expected error")
    } catch let err as RPCRemoteError {
      #expect(err.code == "ERR_UNEXPECTED_STREAM")
    }
  }
}
