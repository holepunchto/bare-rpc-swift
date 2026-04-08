import Foundation
import Testing

@testable import BareRPC

/// Byte-level interop tests against the JavaScript `bare-rpc` reference.
///
/// Each fixture is the hex-encoded output of the JS `header` codec for a known
/// message shape. See `Fixtures/gen_fixtures.js` to regenerate the hex strings.
/// Every test verifies both directions:
///   1. decode: Swift parses the JS-produced bytes into the expected message
///   2. encode: Swift produces byte-identical output for the same message
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
    // Swift currently flattens empty data to nil on decode (documented divergence).
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
    // id=1000 triggers the 3-byte c.uint encoding (0xfd + uint16 LE).
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
    // id=0xFFFFFFFE triggers the 5-byte c.uint encoding (0xfe + uint32 LE).
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

  // MARK: - Response frames

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
