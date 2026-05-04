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
    await f.stream.push(Data([1, 2, 3]))
    await f.stream.end()

    var chunks: [Data] = []
    for try await chunk in f.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1, 2, 3])])
  }

  @Test func multipleChunks() async throws {
    let f = Fixture()
    await f.stream.push(Data([1]))
    await f.stream.push(Data([2]))
    await f.stream.push(Data([3]))
    await f.stream.end()

    var chunks: [Data] = []
    for try await chunk in f.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1]), Data([2]), Data([3])])
  }

  @Test func endFinishesStream() async throws {
    let f = Fixture()
    await f.stream.end()

    var chunks: [Data] = []
    for try await chunk in f.stream {
      chunks.append(chunk)
    }
    #expect(chunks.isEmpty)
  }

  @Test func destroyWithoutErrorFinishesStream() async throws {
    let f = Fixture()
    await f.stream.push(Data([1]))
    await f.stream.destroy()

    var chunks: [Data] = []
    for try await chunk in f.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1])])
  }

  @Test func destroyWithErrorThrows() async throws {
    let f = Fixture()
    await f.stream.push(Data([1]))
    await f.stream.destroy(error: RPCRemoteError(message: "broken", code: "ERR", errno: 42))

    var chunks: [Data] = []
    do {
      for try await chunk in f.stream {
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
    await f.stream.push(Data([1]))
    await f.stream.end()
    await f.stream.push(Data([2]))

    var chunks: [Data] = []
    for try await chunk in f.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1])])
  }

  @Test func pushAfterDestroyIsIgnored() async throws {
    let f = Fixture()
    await f.stream.push(Data([1]))
    await f.stream.destroy()
    await f.stream.push(Data([2]))

    var chunks: [Data] = []
    for try await chunk in f.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1])])
  }

  @Test func doubleEndIsNoop() async throws {
    let f = Fixture()
    await f.stream.push(Data([1]))
    await f.stream.end()
    await f.stream.end()

    var chunks: [Data] = []
    for try await chunk in f.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1])])
  }

  @Test func destroyAfterEndIsNoop() async throws {
    let f = Fixture()
    await f.stream.push(Data([1]))
    await f.stream.end()
    await f.stream.destroy()

    var chunks: [Data] = []
    for try await chunk in f.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1])])
  }

  @Test func endAfterDestroyIsNoop() async throws {
    let f = Fixture()
    await f.stream.push(Data([1]))
    await f.stream.destroy()
    await f.stream.end()

    var chunks: [Data] = []
    for try await chunk in f.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1])])
  }

  @Test func doubleDestroyIsNoop() async throws {
    let f = Fixture()
    await f.stream.push(Data([1]))
    await f.stream.destroy()
    await f.stream.destroy()

    var chunks: [Data] = []
    for try await chunk in f.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([1])])
  }

  @Test func destroyWithErrorNoDataThrows() async throws {
    let f = Fixture()
    await f.stream.destroy(error: RPCRemoteError(message: "fail", code: "ERR"))

    do {
      for try await _ in f.stream {
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
    await f.stream.end()
  }
}
