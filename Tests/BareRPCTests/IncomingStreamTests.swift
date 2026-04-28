import Foundation
import Testing

@testable import BareRPC

@Suite struct IncomingStreamTests {

  private final class Fixture {
    let rpc: RPC
    let delegate: CaptureDelegate
    let stream: IncomingStream

    init(id: UInt = 1, mask: UInt = StreamFlag.request) {
      let delegate = CaptureDelegate()
      let rpc = RPC(delegate: delegate)
      self.delegate = delegate
      self.rpc = rpc
      self.stream = IncomingStream(requestId: id, mask: mask, rpc: rpc)
    }
  }

  @Test func pushedDataIsReadable() async throws {
    let f = Fixture()
    f.stream.push(Data([1, 2, 3]))
    f.stream.end()

    var chunks: [Data] = []
    for try await chunk in f.stream.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1, 2, 3])])
  }

  @Test func multipleChunks() async throws {
    let f = Fixture()
    f.stream.push(Data([1]))
    f.stream.push(Data([2]))
    f.stream.push(Data([3]))
    f.stream.end()

    var chunks: [Data] = []
    for try await chunk in f.stream.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1]), Data([2]), Data([3])])
  }

  @Test func endFinishesStream() async throws {
    let f = Fixture()
    f.stream.end()

    var chunks: [Data] = []
    for try await chunk in f.stream.stream {
      chunks.append(chunk)
    }
    #expect(chunks.isEmpty)
  }

  @Test func destroyWithoutErrorFinishesStream() async throws {
    let f = Fixture()
    f.stream.push(Data([1]))
    f.stream.destroy()

    var chunks: [Data] = []
    for try await chunk in f.stream.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1])])
  }

  @Test func destroyWithErrorThrows() async throws {
    let f = Fixture()
    f.stream.push(Data([1]))
    f.stream.destroy(error: RPCRemoteError(message: "broken", code: "ERR", errno: 42))

    var chunks: [Data] = []
    do {
      for try await chunk in f.stream.stream {
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
    let f = Fixture()
    f.stream.push(Data([1]))
    f.stream.end()
    f.stream.push(Data([2]))

    var chunks: [Data] = []
    for try await chunk in f.stream.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1])])
  }

  @Test func pushAfterDestroyIsIgnored() async throws {
    let f = Fixture()
    f.stream.push(Data([1]))
    f.stream.destroy()
    f.stream.push(Data([2]))

    var chunks: [Data] = []
    for try await chunk in f.stream.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1])])
  }

  @Test func doubleEndIsNoop() async throws {
    let f = Fixture()
    f.stream.push(Data([1]))
    f.stream.end()
    f.stream.end()

    var chunks: [Data] = []
    for try await chunk in f.stream.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1])])
  }

  @Test func destroyAfterEndIsNoop() async throws {
    let f = Fixture()
    f.stream.push(Data([1]))
    f.stream.end()
    f.stream.destroy()

    var chunks: [Data] = []
    for try await chunk in f.stream.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1])])
  }

  @Test func endAfterDestroyIsNoop() async throws {
    let f = Fixture()
    f.stream.push(Data([1]))
    f.stream.destroy()
    f.stream.end()

    var chunks: [Data] = []
    for try await chunk in f.stream.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1])])
  }

  @Test func doubleDestroyIsNoop() async throws {
    let f = Fixture()
    f.stream.push(Data([1]))
    f.stream.destroy()
    f.stream.destroy()

    var chunks: [Data] = []
    for try await chunk in f.stream.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1])])
  }

  @Test func destroyWithErrorNoDataThrows() async throws {
    let f = Fixture()
    f.stream.destroy(error: RPCRemoteError(message: "fail", code: "ERR"))

    do {
      for try await _ in f.stream.stream {
        Issue.record("Expected no data")
      }
      Issue.record("Expected error to be thrown")
    } catch let err as RPCRemoteError {
      #expect(err.message == "fail")
    }
  }

  @Test func responseMaskPreserved() async throws {
    let f = Fixture(id: 5, mask: StreamFlag.response)
    #expect(f.stream.requestId == 5)
    #expect(f.stream.mask == StreamFlag.response)
    f.stream.end()
  }
}
