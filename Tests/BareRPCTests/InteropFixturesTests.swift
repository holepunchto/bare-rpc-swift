import Foundation
import Testing

@testable import BareRPC

/// Byte-level interop against the JS `bare-rpc` reference. Fixtures are
/// hex-encoded frames produced by `Fixtures/gen_fixtures.js`; each test
/// checks Swift decodes them and re-encodes byte-identically.
@Suite struct InteropFixturesTests {

  // MARK: - Request frames

  @Test func requestSimple() throws {
    let fixture = hex("0a00000001012a000568656c6c6f")
    let frame = Messages.encodeRequest(id: 1, command: 42, data: Data("hello".utf8))
    #expect(frame == fixture)

    guard case .request(let req) = try Messages.decodeFrame(fixture) else {
      Issue.record("expected request")
      return
    }
    #expect(req.id == 1)
    #expect(req.command == 42)
    #expect(req.stream == 0)
    #expect(req.data == Data("hello".utf8))
  }

  @Test func requestEmptyData() throws {
    let fixture = hex("050000000102070000")
    let frame = Messages.encodeRequest(id: 2, command: 7, data: Data())
    #expect(frame == fixture)

    guard case .request(let req) = try Messages.decodeFrame(fixture) else {
      Issue.record("expected request")
      return
    }
    #expect(req.id == 2)
    #expect(req.command == 7)
    // Swift flattens empty data to nil on decode (documented divergence).
    #expect(req.data == nil)
  }

  @Test func eventWithData() throws {
    let fixture = hex("090000000100630004deadbeef")
    let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
    let frame = Messages.encodeEvent(command: 99, data: payload)
    #expect(frame == fixture)

    guard case .request(let req) = try Messages.decodeFrame(fixture) else {
      Issue.record("expected request")
      return
    }
    #expect(req.id == 0)
    #expect(req.command == 99)
    #expect(req.data == payload)
  }

  @Test func eventEmptyData() throws {
    let fixture = hex("050000000100630000")
    let frame = Messages.encodeEvent(command: 99, data: Data())
    #expect(frame == fixture)

    guard case .request(let req) = try Messages.decodeFrame(fixture) else {
      Issue.record("expected request")
      return
    }
    #expect(req.id == 0)
    #expect(req.command == 99)
    #expect(req.data == nil)
  }

  @Test func requestLargeCommand() throws {
    // 3-byte c.uint (0xfd + uint16 LE).
    let fixture = hex("090000000101fd2c0100026869")
    let frame = Messages.encodeRequest(id: 1, command: 300, data: Data("hi".utf8))
    #expect(frame == fixture)

    guard case .request(let req) = try Messages.decodeFrame(fixture) else {
      Issue.record("expected request")
      return
    }
    #expect(req.command == 300)
    #expect(req.data == Data("hi".utf8))
  }

  @Test func requestStreamOpenOmitsData() throws {
    let fixture = hex("0400000001030501")
    let frame = Messages.encodeRequest(id: 3, command: 5, stream: StreamFlag.open, data: nil)
    #expect(frame == fixture)

    guard case .request(let req) = try Messages.decodeFrame(fixture) else {
      Issue.record("expected request")
      return
    }
    #expect(req.id == 3)
    #expect(req.command == 5)
    #expect(req.stream == StreamFlag.open)
    #expect(req.data == nil)
  }

  @Test func requestLargeIdVarint() throws {
    // 3-byte c.uint (0xfd + uint16 LE).
    let fixture = hex("0700000001fde803010000")
    let frame = Messages.encodeRequest(id: 1000, command: 1, data: Data())
    #expect(frame == fixture)

    guard case .request(let req) = try Messages.decodeFrame(fixture) else {
      Issue.record("expected request")
      return
    }
    #expect(req.id == 1000)
  }

  @Test func requestMax32IdVarint() throws {
    // 5-byte c.uint (0xfe + uint32 LE).
    let fixture = hex("0c00000001fefeffffff020003010203")
    let frame = Messages.encodeRequest(
      id: 0xFFFF_FFFE, command: 2, data: Data([1, 2, 3]))
    #expect(frame == fixture)

    guard case .request(let req) = try Messages.decodeFrame(fixture) else {
      Issue.record("expected request")
      return
    }
    #expect(req.id == 0xFFFF_FFFE)
    #expect(req.command == 2)
    #expect(req.data == Data([1, 2, 3]))
  }

  @Test func requestId2Pow32Varint() throws {
    // 9-byte c.uint (0xff + uint64 LE).
    let fixture = hex("1000000001ff0000000001000000020003010203")
    let frame = Messages.encodeRequest(
      id: 0x1_0000_0000, command: 2, data: Data([1, 2, 3]))
    #expect(frame == fixture)

    guard case .request(let req) = try Messages.decodeFrame(fixture) else {
      Issue.record("expected request")
      return
    }
    #expect(req.id == 0x1_0000_0000)
    #expect(req.command == 2)
    #expect(req.data == Data([1, 2, 3]))
  }

  // MARK: - Response frames

  @Test func responseEmptyData() throws {
    let fixture = hex("050000000202000000")
    let frame = Messages.encodeResponse(id: 2, data: Data())
    #expect(frame == fixture)

    guard case .response(let resp) = try Messages.decodeFrame(fixture) else {
      Issue.record("expected response")
      return
    }
    #expect(resp.id == 2)
    guard case .success(let data) = resp.result else {
      Issue.record("expected success")
      return
    }
    #expect(data == nil)
  }

  @Test func responseSuccess() throws {
    let fixture = hex("0a0000000201000005776f726c64")
    let frame = Messages.encodeResponse(id: 1, data: Data("world".utf8))
    #expect(frame == fixture)

    guard case .response(let resp) = try Messages.decodeFrame(fixture) else {
      Issue.record("expected response")
      return
    }
    #expect(resp.id == 1)
    #expect(resp.stream == 0)
    guard case .success(let data) = resp.result else {
      Issue.record("expected success")
      return
    }
    #expect(data == Data("world".utf8))
  }

  @Test func responseError() throws {
    let fixture = hex("100000000201010004626f6f6d0545424f4f4d03")
    let frame = Messages.encodeErrorResponse(
      id: 1, message: "boom", code: "EBOOM", errno: -2)
    #expect(frame == fixture)

    guard case .response(let resp) = try Messages.decodeFrame(fixture) else {
      Issue.record("expected response")
      return
    }
    #expect(resp.id == 1)
    guard case .remoteError(let message, let code, let errno) = resp.result else {
      Issue.record("expected remote error")
      return
    }
    #expect(message == "boom")
    #expect(code == "EBOOM")
    #expect(errno == -2)
  }

  @Test func responseErrorZeroErrno() throws {
    let fixture = hex("09000000020501000178014500")
    let frame = Messages.encodeErrorResponse(id: 5, message: "x", code: "E", errno: 0)
    #expect(frame == fixture)

    guard case .response(let resp) = try Messages.decodeFrame(fixture),
      case .remoteError(_, _, let errno) = resp.result
    else {
      Issue.record("expected remote error")
      return
    }
    #expect(errno == 0)
  }

  @Test func responseErrorPositiveErrno() throws {
    // 42 zigzag-encodes as 0x54, not 0x2a.
    let fixture = hex("1000000002010100046f6f707305454f4f505354")
    let frame = Messages.encodeErrorResponse(
      id: 1, message: "oops", code: "EOOPS", errno: 42)
    #expect(frame == fixture)

    guard case .response(let resp) = try Messages.decodeFrame(fixture),
      case .remoteError(_, _, let errno) = resp.result
    else {
      Issue.record("expected remote error")
      return
    }
    #expect(errno == 42)
  }

  @Test func responseErrorNegativeMaxErrno() throws {
    // INT32_MIN — c.int zigzag lower bound.
    let fixture = hex("140000000201010004626f6f6d0545424f4f4dfeffffffff")
    let frame = Messages.encodeErrorResponse(
      id: 1, message: "boom", code: "EBOOM", errno: -2_147_483_648)
    #expect(frame == fixture)

    guard case .response(let resp) = try Messages.decodeFrame(fixture),
      case .remoteError(_, _, let errno) = resp.result
    else {
      Issue.record("expected remote error")
      return
    }
    #expect(errno == -2_147_483_648)
  }

  @Test func responseErrorLongMessage() throws {
    // 3-byte c.utf8 length prefix (0xfd + uint16 LE).
    let longMessage = String(repeating: "a", count: 300)
    let fixture = hex(
      "3601000002010100fd2c01"
        + String(repeating: "61", count: 300)
        + "014501")
    let frame = Messages.encodeErrorResponse(
      id: 1, message: longMessage, code: "E", errno: -1)
    #expect(frame == fixture)

    guard case .response(let resp) = try Messages.decodeFrame(fixture),
      case .remoteError(let message, _, _) = resp.result
    else {
      Issue.record("expected remote error")
      return
    }
    #expect(message == longMessage)
  }

  @Test func responseStreamOpenOmitsData() throws {
    let fixture = hex("0400000002040001")
    let frame = Messages.encodeResponse(id: 4, stream: StreamFlag.open, data: nil)
    #expect(frame == fixture)

    guard case .response(let resp) = try Messages.decodeFrame(fixture) else {
      Issue.record("expected response")
      return
    }
    #expect(resp.id == 4)
    #expect(resp.stream == StreamFlag.open)
    guard case .success(let data) = resp.result else {
      Issue.record("expected success")
      return
    }
    #expect(data == nil)
  }

  // MARK: - Stream frames

  @Test func streamOpenRequestDirectionAck() throws {
    let fixture = hex("050000000303fd0101")
    let frame = Messages.encodeStream(
      id: 3, flags: StreamFlag.request | StreamFlag.open)
    #expect(frame == fixture)

    guard case .stream(let s) = try Messages.decodeFrame(fixture) else {
      Issue.record("expected stream")
      return
    }
    #expect(s.id == 3)
    #expect(s.flags == StreamFlag.request | StreamFlag.open)
  }

  @Test func streamOpenResponseDirection() throws {
    let fixture = hex("050000000304fd0102")
    let frame = Messages.encodeStream(
      id: 4, flags: StreamFlag.response | StreamFlag.open)
    #expect(frame == fixture)

    guard case .stream(let s) = try Messages.decodeFrame(fixture) else {
      Issue.record("expected stream")
      return
    }
    #expect(s.id == 4)
    #expect(s.flags == StreamFlag.response | StreamFlag.open)
  }

  @Test func streamDataRequestDirection() throws {
    let fixture = hex("090000000303fd100103616263")
    let frame = Messages.encodeStream(
      id: 3,
      flags: StreamFlag.request | StreamFlag.data,
      data: Data("abc".utf8))
    #expect(frame == fixture)

    guard case .stream(let s) = try Messages.decodeFrame(fixture) else {
      Issue.record("expected stream")
      return
    }
    #expect(s.id == 3)
    #expect(s.flags == StreamFlag.request | StreamFlag.data)
    #expect(s.data == Data("abc".utf8))
  }

  @Test func streamEndRequestDirection() throws {
    let fixture = hex("050000000303fd2001")
    let frame = Messages.encodeStream(
      id: 3, flags: StreamFlag.request | StreamFlag.end)
    #expect(frame == fixture)

    guard case .stream(let s) = try Messages.decodeFrame(fixture) else {
      Issue.record("expected stream")
      return
    }
    #expect(s.id == 3)
    #expect(s.flags == StreamFlag.request | StreamFlag.end)
    #expect(s.data == nil)
  }

  @Test func streamDataResponseDirection() throws {
    let fixture = hex("090000000304fd10020378797a")
    let frame = Messages.encodeStream(
      id: 4,
      flags: StreamFlag.response | StreamFlag.data,
      data: Data("xyz".utf8))
    #expect(frame == fixture)

    guard case .stream(let s) = try Messages.decodeFrame(fixture) else {
      Issue.record("expected stream")
      return
    }
    #expect(s.id == 4)
    #expect(s.flags == StreamFlag.response | StreamFlag.data)
    #expect(s.data == Data("xyz".utf8))
  }

  @Test func streamEndResponseDirection() throws {
    let fixture = hex("050000000304fd2002")
    let frame = Messages.encodeStream(
      id: 4, flags: StreamFlag.response | StreamFlag.end)
    #expect(frame == fixture)

    guard case .stream(let s) = try Messages.decodeFrame(fixture) else {
      Issue.record("expected stream")
      return
    }
    #expect(s.id == 4)
    #expect(s.flags == StreamFlag.response | StreamFlag.end)
  }

  @Test func streamDestroyRequestDirection() throws {
    let fixture = hex("050000000303fd4001")
    let frame = Messages.encodeStream(
      id: 3, flags: StreamFlag.request | StreamFlag.destroy)
    #expect(frame == fixture)

    guard case .stream(let s) = try Messages.decodeFrame(fixture) else {
      Issue.record("expected stream")
      return
    }
    #expect(s.id == 3)
    #expect(s.flags == StreamFlag.request | StreamFlag.destroy)
  }

  @Test func streamDestroyResponseDirection() throws {
    let fixture = hex("050000000304fd4002")
    let frame = Messages.encodeStream(
      id: 4, flags: StreamFlag.response | StreamFlag.destroy)
    #expect(frame == fixture)

    guard case .stream(let s) = try Messages.decodeFrame(fixture) else {
      Issue.record("expected stream")
      return
    }
    #expect(s.id == 4)
    #expect(s.flags == StreamFlag.response | StreamFlag.destroy)
  }

  @Test func streamCloseRequestDirection() throws {
    let fixture = hex("050000000303fd0201")
    let frame = Messages.encodeStream(
      id: 3, flags: StreamFlag.request | StreamFlag.close)
    #expect(frame == fixture)

    guard case .stream(let s) = try Messages.decodeFrame(fixture) else {
      Issue.record("expected stream")
      return
    }
    #expect(s.id == 3)
    #expect(s.flags == StreamFlag.request | StreamFlag.close)
    #expect(s.data == nil)
  }

  @Test func streamCloseResponseDirection() throws {
    let fixture = hex("050000000304fd0202")
    let frame = Messages.encodeStream(
      id: 4, flags: StreamFlag.response | StreamFlag.close)
    #expect(frame == fixture)

    guard case .stream(let s) = try Messages.decodeFrame(fixture) else {
      Issue.record("expected stream")
      return
    }
    #expect(s.id == 4)
    #expect(s.flags == StreamFlag.response | StreamFlag.close)
    #expect(s.data == nil)
  }

  @Test func streamErrorRequestDirection() throws {
    let fixture = hex("110000000303fd8001046e6f706505454e4f504501")
    let err = RPCRemoteError(message: "nope", code: "ENOPE", errno: -1)
    let frame = Messages.encodeStream(
      id: 3,
      flags: StreamFlag.request | StreamFlag.error,
      error: err)
    #expect(frame == fixture)

    guard case .stream(let s) = try Messages.decodeFrame(fixture) else {
      Issue.record("expected stream")
      return
    }
    #expect(s.id == 3)
    #expect(s.flags == StreamFlag.request | StreamFlag.error)
    #expect(s.error?.message == "nope")
    #expect(s.error?.code == "ENOPE")
    #expect(s.error?.errno == -1)
  }

  @Test func streamErrorResponseDirection() throws {
    let fixture = hex("110000000304fd800204626f6f6d0545424f4f4d01")
    let err = RPCRemoteError(message: "boom", code: "EBOOM", errno: -1)
    let frame = Messages.encodeStream(
      id: 4,
      flags: StreamFlag.response | StreamFlag.error,
      error: err)
    #expect(frame == fixture)

    guard case .stream(let s) = try Messages.decodeFrame(fixture) else {
      Issue.record("expected stream")
      return
    }
    #expect(s.id == 4)
    #expect(s.flags == StreamFlag.response | StreamFlag.error)
    #expect(s.error?.message == "boom")
    #expect(s.error?.code == "EBOOM")
    #expect(s.error?.errno == -1)
  }

  // MARK: - Helpers

  private func hex(_ string: String) -> Data {
    precondition(string.count % 2 == 0, "hex string must have even length")
    var data = Data(capacity: string.count / 2)
    var index = string.startIndex
    while index < string.endIndex {
      let next = string.index(index, offsetBy: 2)
      guard let byte = UInt8(string[index..<next], radix: 16) else {
        preconditionFailure("invalid hex: \(string)")
      }
      data.append(byte)
      index = next
    }
    return data
  }
}
