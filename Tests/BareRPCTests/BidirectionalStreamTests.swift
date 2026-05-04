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
      guard let responseStream = req.createResponseStream() else {
        Issue.record("Expected to create response stream")
        return
      }
      for try await chunk in requestStream {
        await responseStream.write(chunk)
      }
      responseStream.end()
    }

    let (outgoing, incoming) = try await pair.client.createBidirectionalStream(command: 42)

    await outgoing.write(Data([1, 2, 3]))
    await outgoing.write(Data([4, 5, 6]))
    outgoing.end()

    var received: [Data] = []
    for try await chunk in incoming {
      received.append(chunk)
    }
    #expect(received == [Data([1, 2, 3]), Data([4, 5, 6])])
  }
}
