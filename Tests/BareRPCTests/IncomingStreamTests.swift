import Foundation
import Testing

@testable import BareRPC

@Suite struct IncomingStreamTests {

  @Test func pushedDataIsReadable() async throws {
    let incoming = IncomingStream(requestId: 1, mask: StreamFlag.request)
    incoming.push(Data([1, 2, 3]))
    incoming.end()

    var chunks: [Data] = []
    for try await chunk in incoming.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1, 2, 3])])
  }

  @Test func multipleChunks() async throws {
    let incoming = IncomingStream(requestId: 1, mask: StreamFlag.request)
    incoming.push(Data([1]))
    incoming.push(Data([2]))
    incoming.push(Data([3]))
    incoming.end()

    var chunks: [Data] = []
    for try await chunk in incoming.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1]), Data([2]), Data([3])])
  }

  @Test func endFinishesStream() async throws {
    let incoming = IncomingStream(requestId: 1, mask: StreamFlag.request)
    incoming.end()

    var chunks: [Data] = []
    for try await chunk in incoming.stream {
      chunks.append(chunk)
    }
    #expect(chunks.isEmpty)
  }

  @Test func destroyWithoutErrorFinishesStream() async throws {
    let incoming = IncomingStream(requestId: 1, mask: StreamFlag.request)
    incoming.push(Data([1]))
    incoming.destroy()

    var chunks: [Data] = []
    for try await chunk in incoming.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1])])
  }

  @Test func destroyWithErrorThrows() async throws {
    let incoming = IncomingStream(requestId: 1, mask: StreamFlag.request)
    incoming.push(Data([1]))
    incoming.destroy(error: RPCRemoteError(message: "broken", code: "ERR", errno: 42))

    var chunks: [Data] = []
    do {
      for try await chunk in incoming.stream {
        chunks.append(chunk)
      }
      Issue.record("Expected error to be thrown")
    } catch let err as RPCRemoteError {
      #expect(err.message == "broken")
      #expect(err.code == "ERR")
      #expect(err.errno == 42)
    }
    #expect(chunks == [Data([1])])
  }

  @Test func pushAfterEndIsIgnored() async throws {
    let incoming = IncomingStream(requestId: 1, mask: StreamFlag.request)
    incoming.push(Data([1]))
    incoming.end()
    incoming.push(Data([2]))

    var chunks: [Data] = []
    for try await chunk in incoming.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1])])
  }

  @Test func pushAfterDestroyIsIgnored() async throws {
    let incoming = IncomingStream(requestId: 1, mask: StreamFlag.request)
    incoming.push(Data([1]))
    incoming.destroy()
    incoming.push(Data([2]))

    var chunks: [Data] = []
    for try await chunk in incoming.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1])])
  }

  @Test func doubleEndIsNoop() async throws {
    let incoming = IncomingStream(requestId: 1, mask: StreamFlag.request)
    incoming.push(Data([1]))
    incoming.end()
    incoming.end()

    var chunks: [Data] = []
    for try await chunk in incoming.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1])])
  }

  @Test func destroyAfterEndIsNoop() async throws {
    let incoming = IncomingStream(requestId: 1, mask: StreamFlag.request)
    incoming.push(Data([1]))
    incoming.end()
    incoming.destroy()

    var chunks: [Data] = []
    for try await chunk in incoming.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1])])
  }

  @Test func endAfterDestroyIsNoop() async throws {
    let incoming = IncomingStream(requestId: 1, mask: StreamFlag.request)
    incoming.push(Data([1]))
    incoming.destroy()
    incoming.end()

    var chunks: [Data] = []
    for try await chunk in incoming.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1])])
  }

  @Test func doubleDestroyIsNoop() async throws {
    let incoming = IncomingStream(requestId: 1, mask: StreamFlag.request)
    incoming.push(Data([1]))
    incoming.destroy()
    incoming.destroy()

    var chunks: [Data] = []
    for try await chunk in incoming.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1])])
  }

  @Test func destroyWithErrorNoDataThrows() async throws {
    let incoming = IncomingStream(requestId: 1, mask: StreamFlag.request)
    incoming.destroy(error: RPCRemoteError(message: "fail", code: "ERR"))

    do {
      for try await _ in incoming.stream {
        Issue.record("Expected no data")
      }
      Issue.record("Expected error to be thrown")
    } catch let err as RPCRemoteError {
      #expect(err.message == "fail")
    }
  }

  @Test func responseMaskPreserved() async throws {
    let incoming = IncomingStream(requestId: 5, mask: StreamFlag.response)
    #expect(incoming.requestId == 5)
    #expect(incoming.mask == StreamFlag.response)
    incoming.end()
  }
}
