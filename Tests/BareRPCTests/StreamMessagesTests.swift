import Foundation
import Testing

@testable import BareRPC

@Suite struct StreamMessagesTests {

  @Test func streamOpenRequestRoundtrip() throws {
    let frame = Messages.encodeStream(
      id: 5, flags: StreamFlag.request | StreamFlag.open)
    let msg = try Messages.decodeFrame(frame)
    guard case .stream(let s) = msg else {
      Issue.record("Expected stream message")
      return
    }
    #expect(s.id == 5)
    #expect(s.flags == StreamFlag.request | StreamFlag.open)
    #expect(s.data == nil)
    #expect(s.error == nil)
  }

  @Test func streamOpenResponseRoundtrip() throws {
    let frame = Messages.encodeStream(
      id: 3, flags: StreamFlag.response | StreamFlag.open)
    let msg = try Messages.decodeFrame(frame)
    guard case .stream(let s) = msg else {
      Issue.record("Expected stream message")
      return
    }
    #expect(s.id == 3)
    #expect(s.flags == StreamFlag.response | StreamFlag.open)
    #expect(s.data == nil)
    #expect(s.error == nil)
  }

  @Test func streamDataRoundtrip() throws {
    let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
    let frame = Messages.encodeStream(
      id: 7, flags: StreamFlag.request | StreamFlag.data, data: payload)
    let msg = try Messages.decodeFrame(frame)
    guard case .stream(let s) = msg else {
      Issue.record("Expected stream message")
      return
    }
    #expect(s.id == 7)
    #expect(s.flags == StreamFlag.request | StreamFlag.data)
    #expect(s.data == payload)
    #expect(s.error == nil)
  }

  @Test func streamEndRoundtrip() throws {
    let frame = Messages.encodeStream(
      id: 2, flags: StreamFlag.request | StreamFlag.end)
    let msg = try Messages.decodeFrame(frame)
    guard case .stream(let s) = msg else {
      Issue.record("Expected stream message")
      return
    }
    #expect(s.id == 2)
    #expect(s.flags == StreamFlag.request | StreamFlag.end)
    #expect(s.data == nil)
  }

  @Test func streamCloseRoundtrip() throws {
    let frame = Messages.encodeStream(
      id: 4, flags: StreamFlag.response | StreamFlag.close)
    let msg = try Messages.decodeFrame(frame)
    guard case .stream(let s) = msg else {
      Issue.record("Expected stream message")
      return
    }
    #expect(s.id == 4)
    #expect(s.flags == StreamFlag.response | StreamFlag.close)
  }

  @Test func streamDestroyRoundtrip() throws {
    let frame = Messages.encodeStream(
      id: 6, flags: StreamFlag.request | StreamFlag.destroy)
    let msg = try Messages.decodeFrame(frame)
    guard case .stream(let s) = msg else {
      Issue.record("Expected stream message")
      return
    }
    #expect(s.id == 6)
    #expect(s.flags == StreamFlag.request | StreamFlag.destroy)
  }

  @Test func streamErrorRoundtrip() throws {
    let frame = Messages.encodeStream(
      id: 8, flags: StreamFlag.response | StreamFlag.close | StreamFlag.error,
      error: RPCRemoteError(message: "stream broke", code: "ESTREAM", errno: 99))
    let msg = try Messages.decodeFrame(frame)
    guard case .stream(let s) = msg else {
      Issue.record("Expected stream message")
      return
    }
    #expect(s.id == 8)
    #expect(s.flags == StreamFlag.response | StreamFlag.close | StreamFlag.error)
    #expect(s.data == nil)
    #expect(s.error?.message == "stream broke")
    #expect(s.error?.code == "ESTREAM")
    #expect(s.error?.errno == 99)
  }

  @Test func streamDataWithEmptyPayload() throws {
    let frame = Messages.encodeStream(
      id: 1, flags: StreamFlag.request | StreamFlag.data, data: Data())
    let msg = try Messages.decodeFrame(frame)
    guard case .stream(let s) = msg else {
      Issue.record("Expected stream message")
      return
    }
    #expect(s.flags == StreamFlag.request | StreamFlag.data)
    #expect(s.data == nil)
    #expect(s.error == nil)
  }

  @Test func streamErrorTakesPrecedenceOverData() throws {
    let flags = StreamFlag.response | StreamFlag.close | StreamFlag.error | StreamFlag.data
    let frame = Messages.encodeStream(
      id: 1, flags: flags,
      data: Data([1, 2, 3]),
      error: RPCRemoteError(message: "fail", code: "ERR", errno: 1))
    let msg = try Messages.decodeFrame(frame)
    guard case .stream(let s) = msg else {
      Issue.record("Expected stream message")
      return
    }
    #expect(s.error?.message == "fail")
    #expect(s.data == nil)
  }

  @Test func streamFramePrefixIsBodyLength() throws {
    let payload = Data([1, 2, 3])
    let frame = Messages.encodeStream(
      id: 1, flags: StreamFlag.request | StreamFlag.data, data: payload)
    let bodyLen =
      UInt32(frame[0]) | (UInt32(frame[1]) << 8) | (UInt32(frame[2]) << 16)
      | (UInt32(frame[3]) << 24)
    #expect(Int(bodyLen) == frame.count - 4)
  }

  @Test func requestWithStreamFieldPreserved() throws {
    let frame = Messages.encodeRequest(id: 5, command: 1, stream: StreamFlag.open, data: nil)
    let msg = try Messages.decodeFrame(frame)
    guard case .request(let req) = msg else {
      Issue.record("Expected request")
      return
    }
    #expect(req.id == 5)
    #expect(req.command == 1)
    #expect(req.stream == StreamFlag.open)
    #expect(req.data == nil)
  }

  @Test func requestWithStreamOmitsDataFromWire() throws {
    // JS wire format: when stream != 0, no data field is encoded
    // Frame should be: [4-byte len][type=1][id][command][stream] — no buffer field
    let frame = Messages.encodeRequest(id: 5, command: 1, stream: StreamFlag.open, data: nil)
    let bodyLen =
      UInt32(frame[0]) | (UInt32(frame[1]) << 8) | (UInt32(frame[2]) << 16)
      | (UInt32(frame[3]) << 24)
    // Compare with a stream=0 request with nil data to verify stream!=0 is shorter
    let normalFrame = Messages.encodeRequest(id: 5, command: 1, stream: 0, data: nil)
    let normalBodyLen =
      UInt32(normalFrame[0]) | (UInt32(normalFrame[1]) << 8) | (UInt32(normalFrame[2]) << 16)
      | (UInt32(normalFrame[3]) << 24)
    // stream=0 frame has an extra buffer field (at minimum 1 byte for length=0)
    #expect(bodyLen < normalBodyLen)
  }

  @Test func responseWithStreamFieldPreserved() throws {
    let frame = Messages.encodeResponse(id: 5, stream: StreamFlag.open, data: nil)
    let msg = try Messages.decodeFrame(frame)
    guard case .response(let resp) = msg else {
      Issue.record("Expected response")
      return
    }
    #expect(resp.id == 5)
    #expect(resp.stream == StreamFlag.open)
    guard case .success(let data) = resp.result else {
      Issue.record("Expected success")
      return
    }
    #expect(data == nil)
  }

  @Test func responseWithStreamOmitsDataFromWire() throws {
    // JS wire format: when stream != 0 and no error, no data field is encoded
    let frame = Messages.encodeResponse(id: 5, stream: StreamFlag.open, data: nil)
    let bodyLen =
      UInt32(frame[0]) | (UInt32(frame[1]) << 8) | (UInt32(frame[2]) << 16)
      | (UInt32(frame[3]) << 24)
    let normalFrame = Messages.encodeResponse(id: 5, stream: 0, data: nil)
    let normalBodyLen =
      UInt32(normalFrame[0]) | (UInt32(normalFrame[1]) << 8) | (UInt32(normalFrame[2]) << 16)
      | (UInt32(normalFrame[3]) << 24)
    #expect(bodyLen < normalBodyLen)
  }
}
