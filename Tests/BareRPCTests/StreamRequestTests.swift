import Foundation
import Testing

@testable import BareRPC

@Suite struct StreamRequestTests {

  // Client opens a request stream, writes chunks, ends it; server collects and replies.
  @Test func streamRequestWithScalarReply() async throws {
    let pair = RPCPair()

    pair.serverDelegate.onRequest = { req in
      guard let requestStream = req.requestStream else {
        Issue.record("Expected request stream")
        return
      }
      var chunks: [Data] = []
      for try await chunk in requestStream {
        chunks.append(chunk)
      }
      let combined = chunks.reduce(Data(), +)
      await req.reply(combined)
    }

    let (outgoing, response) = try await pair.client.streamRequest(command: 5)
    await outgoing.write(Data([1, 2, 3]))
    await outgoing.write(Data([4, 5]))
    await outgoing.end()

    #expect(try await response() == Data([1, 2, 3, 4, 5]))
  }

  // Server rejects — response() throws RPCRemoteError.
  @Test func streamRequestServerReject() async throws {
    let pair = RPCPair()

    pair.serverDelegate.onRequest = { req in
      guard req.requestStream != nil else { return }
      await req.reject("bad input", code: "ERR_BAD", errno: 0)
    }

    let (outgoing, response) = try await pair.client.streamRequest(command: 1)
    await outgoing.end()

    do {
      _ = try await response()
      Issue.record("Expected error")
    } catch let err as RPCRemoteError {
      #expect(err.message == "bad input")
      #expect(err.code == "ERR_BAD")
    }
  }

  // Server replies with nil — response() returns nil.
  @Test func streamRequestNilReply() async throws {
    let pair = RPCPair()

    pair.serverDelegate.onRequest = { req in
      guard req.requestStream != nil else { return }
      await req.reply(nil)
    }

    let (outgoing, response) = try await pair.client.streamRequest(command: 1)
    await outgoing.end()

    #expect(try await response() == nil)
  }

  // Connection failure before reply drains the pending continuation.
  @Test func failDrainsPendingStreamRequest() async throws {
    let captureDelegate = CaptureDelegate()
    let rpc = RPC(delegate: captureDelegate, maxFrameSize: 100)

    let (_, response) = try await rpc.streamRequest(command: 1)
    try await Task.sleep(nanoseconds: 100_000_000)

    await rpc.receive(makeRawHeader(claimingBodyLen: 200))

    do {
      _ = try await response()
      Issue.record("Expected frameTooLarge")
    } catch let err as RPCError {
      guard case .frameTooLarge = err else {
        Issue.record("Expected frameTooLarge, got \(err)")
        return
      }
    }
  }

  // Calling streamRequest after fail throws immediately.
  @Test func streamRequestAfterFailThrows() async throws {
    let captureDelegate = CaptureDelegate()
    let rpc = RPC(delegate: captureDelegate, maxFrameSize: 50)

    await rpc.receive(makeRawHeader(claimingBodyLen: 100))

    do {
      _ = try await rpc.streamRequest(command: 1)
      Issue.record("Expected frameTooLarge")
    } catch let err as RPCError {
      guard case .frameTooLarge = err else {
        Issue.record("Expected frameTooLarge, got \(err)")
        return
      }
    }
  }
}
