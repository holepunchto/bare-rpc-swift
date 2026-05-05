import Foundation
import Testing

@testable import BareRPC

@Suite struct OutgoingStreamTests {

  private final class Fixture {
    let rpc: RPC
    let delegate: CaptureDelegate
    let stream: OutgoingStream
    var sent: [Data] = []

    init(mask: UInt = StreamFlag.request) {
      let delegate = CaptureDelegate()
      let rpc = RPC(delegate: delegate)
      let stream = OutgoingStream(requestId: 1, mask: mask, rpc: rpc)
      self.delegate = delegate
      self.rpc = rpc
      self.stream = stream
      delegate.onSend = { [weak self] data in self?.sent.append(data) }
    }
  }

  private func decodeStream(_ frame: Data) throws -> StreamMessage {
    let msg = try Messages.decodeFrame(frame)
    guard case .stream(let s) = msg else {
      Issue.record("Expected stream message")
      fatalError()
    }
    return s
  }

  @Test func writeSendsDataFlag() async throws {
    let f = Fixture()
    let payload = Data([0xDE, 0xAD])
    await f.stream.write(payload)
    #expect(f.sent.count == 1)
    let s = try decodeStream(f.sent[0])
    #expect(s.id == 1)
    #expect(s.flags == StreamFlag.request | StreamFlag.data)
    #expect(s.data == payload)
  }

  @Test func endSendsEndThenClose() async throws {
    let f = Fixture()
    await f.stream.end()
    #expect(f.sent.count == 2)
    let first = try decodeStream(f.sent[0])
    #expect(first.flags == StreamFlag.request | StreamFlag.end)
    let second = try decodeStream(f.sent[1])
    #expect(second.flags == StreamFlag.request | StreamFlag.close)
  }

  @Test func destroyWithoutErrorSendsClose() async throws {
    let f = Fixture()
    await f.stream.destroy()
    #expect(f.sent.count == 1)
    let s = try decodeStream(f.sent[0])
    #expect(s.flags == StreamFlag.request | StreamFlag.close)
  }

  @Test func destroyWithErrorSendsCloseAndError() async throws {
    let f = Fixture()
    await f.stream.destroy(error: RPCRemoteError(message: "broken", code: "ERR", errno: 42))
    #expect(f.sent.count == 1)
    let s = try decodeStream(f.sent[0])
    #expect(s.flags == StreamFlag.request | StreamFlag.close | StreamFlag.error)
    #expect(s.error?.message == "broken")
    #expect(s.error?.code == "ERR")
    #expect(s.error?.errno == 42)
  }

  @Test func writeAfterEndIsNoop() async throws {
    let f = Fixture()
    await f.stream.end()
    let countAfterEnd = f.sent.count
    await f.stream.write(Data([1, 2, 3]))
    #expect(f.sent.count == countAfterEnd)
  }

  @Test func doubleEndIsNoop() async throws {
    let f = Fixture()
    await f.stream.end()
    let countAfterEnd = f.sent.count
    await f.stream.end()
    #expect(f.sent.count == countAfterEnd)
  }

  @Test func writeAfterDestroyIsNoop() async throws {
    let f = Fixture()
    await f.stream.destroy()
    let countAfterDestroy = f.sent.count
    await f.stream.write(Data([1, 2, 3]))
    #expect(f.sent.count == countAfterDestroy)
  }

  @Test func endAfterDestroyIsNoop() async throws {
    let f = Fixture()
    await f.stream.destroy()
    let countAfterDestroy = f.sent.count
    await f.stream.end()
    #expect(f.sent.count == countAfterDestroy)
  }

  @Test func multipleWritesThenEnd() async throws {
    let f = Fixture()
    await f.stream.write(Data([1]))
    await f.stream.write(Data([2]))
    await f.stream.write(Data([3]))
    await f.stream.end()
    // 3 DATA + 1 END + 1 CLOSE = 5 frames
    #expect(f.sent.count == 5)
    let d1 = try decodeStream(f.sent[0])
    #expect(d1.flags == StreamFlag.request | StreamFlag.data)
    #expect(d1.data == Data([1]))
    let d3 = try decodeStream(f.sent[2])
    #expect(d3.data == Data([3]))
    let endMsg = try decodeStream(f.sent[3])
    #expect(endMsg.flags == StreamFlag.request | StreamFlag.end)
    let closeMsg = try decodeStream(f.sent[4])
    #expect(closeMsg.flags == StreamFlag.request | StreamFlag.close)
  }

  @Test func endWithResponseMask() async throws {
    let f = Fixture(mask: StreamFlag.response)
    await f.stream.write(Data([0xAB]))
    await f.stream.end()
    let dataMsg = try decodeStream(f.sent[0])
    #expect(dataMsg.flags == StreamFlag.response | StreamFlag.data)
    let endMsg = try decodeStream(f.sent[1])
    #expect(endMsg.flags == StreamFlag.response | StreamFlag.end)
    let closeMsg = try decodeStream(f.sent[2])
    #expect(closeMsg.flags == StreamFlag.response | StreamFlag.close)
  }

  @Test func destroyAfterEndIsNoop() async throws {
    let f = Fixture()
    await f.stream.end()
    let countAfterEnd = f.sent.count
    await f.stream.destroy()
    #expect(f.sent.count == countAfterEnd)
  }

  @Test func writeWhileCorkSuspendsUntilUncork() async throws {
    let f = Fixture()
    await f.stream.cork()

    var writeCompleted = false
    let writeTask = Task {
      await f.stream.write(Data([0xAB]))
      writeCompleted = true
    }

    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(!writeCompleted)
    #expect(f.sent.isEmpty)

    await f.stream.uncork()
    await writeTask.value

    #expect(writeCompleted)
    #expect(f.sent.count == 1)
    let s = try decodeStream(f.sent[0])
    #expect(s.flags == StreamFlag.request | StreamFlag.data)
    #expect(s.data == Data([0xAB]))
  }

}
