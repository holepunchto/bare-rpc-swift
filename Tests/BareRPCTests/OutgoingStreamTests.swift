import Foundation
import Testing

@testable import BareRPC

@Suite struct OutgoingStreamTests {

  private func capture(_ mask: UInt = StreamFlag.request) -> (OutgoingStream, () -> [Data]) {
    var sent: [Data] = []
    let stream = OutgoingStream(requestId: 1, mask: mask) { data in
      sent.append(data)
    }
    return (stream, { sent })
  }

  private func decodeStream(_ frame: Data) throws -> StreamMessage {
    let msg = try Messages.decodeFrame(frame)
    guard case .stream(let s) = msg else {
      Issue.record("Expected stream message")
      fatalError()
    }
    return s
  }

  @Test func writeSendsDataFlag() throws {
    let (stream, sent) = capture()
    let payload = Data([0xDE, 0xAD])
    stream.write(payload)
    #expect(sent().count == 1)
    let s = try decodeStream(sent()[0])
    #expect(s.id == 1)
    #expect(s.flags == StreamFlag.request | StreamFlag.data)
    #expect(s.data == payload)
  }

  @Test func endSendsEndThenClose() throws {
    let (stream, sent) = capture()
    stream.end()
    #expect(sent().count == 2)
    let first = try decodeStream(sent()[0])
    #expect(first.flags == StreamFlag.request | StreamFlag.end)
    let second = try decodeStream(sent()[1])
    #expect(second.flags == StreamFlag.request | StreamFlag.close)
  }

  @Test func destroyWithoutErrorSendsClose() throws {
    let (stream, sent) = capture()
    stream.destroy()
    #expect(sent().count == 1)
    let s = try decodeStream(sent()[0])
    #expect(s.flags == StreamFlag.request | StreamFlag.close)
  }

  @Test func destroyWithErrorSendsCloseAndError() throws {
    let (stream, sent) = capture()
    stream.destroy(error: RPCRemoteError(message: "broken", code: "ERR", errno: 42))
    #expect(sent().count == 1)
    let s = try decodeStream(sent()[0])
    #expect(s.flags == StreamFlag.request | StreamFlag.close | StreamFlag.error)
    #expect(s.error?.message == "broken")
    #expect(s.error?.code == "ERR")
    #expect(s.error?.errno == 42)
  }

  @Test func writeAfterEndIsNoop() throws {
    let (stream, sent) = capture()
    stream.end()
    let countAfterEnd = sent().count
    stream.write(Data([1, 2, 3]))
    #expect(sent().count == countAfterEnd)
  }

  @Test func doubleEndIsNoop() throws {
    let (stream, sent) = capture()
    stream.end()
    let countAfterEnd = sent().count
    stream.end()
    #expect(sent().count == countAfterEnd)
  }

  @Test func writeAfterDestroyIsNoop() throws {
    let (stream, sent) = capture()
    stream.destroy()
    let countAfterDestroy = sent().count
    stream.write(Data([1, 2, 3]))
    #expect(sent().count == countAfterDestroy)
  }

  @Test func endAfterDestroyIsNoop() throws {
    let (stream, sent) = capture()
    stream.destroy()
    let countAfterDestroy = sent().count
    stream.end()
    #expect(sent().count == countAfterDestroy)
  }

  @Test func multipleWritesThenEnd() throws {
    let (stream, sent) = capture()
    stream.write(Data([1]))
    stream.write(Data([2]))
    stream.write(Data([3]))
    stream.end()
    // 3 DATA + 1 END + 1 CLOSE = 5 frames
    #expect(sent().count == 5)
    let d1 = try decodeStream(sent()[0])
    #expect(d1.flags == StreamFlag.request | StreamFlag.data)
    #expect(d1.data == Data([1]))
    let d3 = try decodeStream(sent()[2])
    #expect(d3.data == Data([3]))
    let endMsg = try decodeStream(sent()[3])
    #expect(endMsg.flags == StreamFlag.request | StreamFlag.end)
    let closeMsg = try decodeStream(sent()[4])
    #expect(closeMsg.flags == StreamFlag.request | StreamFlag.close)
  }

  @Test func endWithResponseMask() throws {
    let (stream, sent) = capture(StreamFlag.response)
    stream.write(Data([0xAB]))
    stream.end()
    let dataMsg = try decodeStream(sent()[0])
    #expect(dataMsg.flags == StreamFlag.response | StreamFlag.data)
    let endMsg = try decodeStream(sent()[1])
    #expect(endMsg.flags == StreamFlag.response | StreamFlag.end)
    let closeMsg = try decodeStream(sent()[2])
    #expect(closeMsg.flags == StreamFlag.response | StreamFlag.close)
  }

  @Test func destroyAfterEndIsNoop() throws {
    let (stream, sent) = capture()
    stream.end()
    let countAfterEnd = sent().count
    stream.destroy()
    #expect(sent().count == countAfterEnd)
  }

}
