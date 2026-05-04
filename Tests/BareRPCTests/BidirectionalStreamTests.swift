import Foundation
import Testing

@testable import BareRPC

@Suite struct BidirectionalStreamTests {

  @Test func bidirectionalEcho() async throws {
    let pair = RPCPair()

    pair.serverDelegate.onRequest = { req in
      guard let requestStream = req.requestStream else {
        Issue.record("Expected request stream")
        return
      }
      guard let responseStream = await req.createResponseStream() else {
        Issue.record("Expected to create response stream")
        return
      }
      for try await chunk in requestStream {
        await responseStream.write(chunk)
      }
      await responseStream.end()
    }

    let (outgoing, incoming) = try await pair.client.createBidirectionalStream(command: 42)

    await outgoing.write(Data([1, 2, 3]))
    await outgoing.write(Data([4, 5, 6]))
    await outgoing.end()

    var received: [Data] = []
    for try await chunk in incoming {
      received.append(chunk)
    }
    #expect(received == [Data([1, 2, 3]), Data([4, 5, 6])])
  }

  @Test func bidirectionalServerDestroysResponseStream() async throws {
    let pair = RPCPair()

    pair.serverDelegate.onRequest = { req in
      guard let responseStream = await req.createResponseStream() else { return }
      await responseStream.destroy(
        error: RPCRemoteError(message: "server error", code: "ERR_SERVER"))
    }

    let (_, incoming) = try await pair.client.createBidirectionalStream(command: 1)

    do {
      for try await _ in incoming {}
      Issue.record("Expected error")
    } catch let err as RPCRemoteError {
      #expect(err.message == "server error")
      #expect(err.code == "ERR_SERVER")
    }
  }

  @Test func bidirectionalClientDestroysRequestStream() async throws {
    let pair = RPCPair()

    try await confirmation { confirm in
      pair.serverDelegate.onRequest = { req in
        guard let requestStream = req.requestStream else {
          Issue.record("Expected request stream")
          return
        }
        _ = await req.createResponseStream()
        var chunks: [Data] = []
        for try await chunk in requestStream {
          chunks.append(chunk)
        }
        #expect(chunks == [Data([0xAB])])
        confirm()
      }

      let (outgoing, _) = try await pair.client.createBidirectionalStream(command: 1)
      await outgoing.write(Data([0xAB]))
      await outgoing.destroy()

      try await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  @Test func bidirectionalMultiChunkEcho() async throws {
    let pair = RPCPair()

    pair.serverDelegate.onRequest = { req in
      guard let requestStream = req.requestStream,
        let responseStream = await req.createResponseStream()
      else { return }
      for try await chunk in requestStream {
        await responseStream.write(chunk)
      }
      await responseStream.end()
    }

    let (outgoing, incoming) = try await pair.client.createBidirectionalStream(command: 1)

    // Read concurrently with writes — required for bidir: sequential write-then-read
    // can deadlock if the echo path's receive buffer fills before the client starts reading.
    let readTask = Task {
      var result: [Data] = []
      for try await chunk in incoming { result.append(chunk) }
      return result
    }

    for i in 0..<16 {
      await outgoing.write(Data([UInt8(i)]))
    }
    await outgoing.end()

    let received = try await readTask.value
    #expect(received.count == 16)
    #expect(received[0] == Data([0]))
    #expect(received[15] == Data([15]))
  }

  @Test func createBidirectionalStreamAfterFailThrowsFailureError() async throws {
    let captureDelegate = CaptureDelegate()
    let rpc = RPC(delegate: captureDelegate, maxFrameSize: 50)

    await rpc.receive(makeRawHeader(claimingBodyLen: 200))

    do {
      _ = try await rpc.createBidirectionalStream(command: 1)
      Issue.record("Expected frameTooLarge")
    } catch let err as RPCError {
      guard case .frameTooLarge = err else {
        Issue.record("Expected frameTooLarge, got \(err)")
        return
      }
    }
  }
}
