import Foundation
// Tests/BareRPCTests/MessagesTests.swift
import Testing

@testable import BareRPC

@Suite struct MessagesTests {

  // --- Request encoding/decoding ---

  @Test func requestRoundtrip() throws {
    let payload = Data([1, 2, 3, 4])
    let frame = Messages.encodeRequest(id: 5, command: 1, data: payload)
    let msg = try Messages.decodeFrame(frame)
    guard case .request(let req) = msg else {
      Issue.record("Expected request")
      return
    }
    #expect(req.id == 5)
    #expect(req.command == 1)
    #expect(req.data == payload)
  }

  @Test func eventRoundtrip() throws {
    let payload = Data([0xAB])
    let frame = Messages.encodeEvent(command: 2, data: payload)
    let msg = try Messages.decodeFrame(frame)
    guard case .request(let req) = msg else {
      Issue.record("Expected request")
      return
    }
    #expect(req.id == 0)
    #expect(req.command == 2)
    #expect(req.data == payload)
  }

  @Test func requestWithNilData() throws {
    let frame = Messages.encodeRequest(id: 1, command: 3, data: nil)
    let msg = try Messages.decodeFrame(frame)
    guard case .request(let req) = msg else {
      Issue.record("Expected request")
      return
    }
    #expect(req.data == nil)
  }

  // --- Response encoding/decoding ---

  @Test func successResponseRoundtrip() throws {
    let payload = Data([10, 20, 30])
    let frame = Messages.encodeResponse(id: 7, data: payload)
    let msg = try Messages.decodeFrame(frame)
    guard case .response(let resp) = msg else {
      Issue.record("Expected response")
      return
    }
    #expect(resp.id == 7)
    guard case .success(let data) = resp.result else {
      Issue.record("Expected success")
      return
    }
    #expect(data == payload)
  }

  @Test func successResponseWithNilData() throws {
    let frame = Messages.encodeResponse(id: 3, data: nil)
    let msg = try Messages.decodeFrame(frame)
    guard case .response(let resp) = msg else {
      Issue.record("Expected response")
      return
    }
    guard case .success(let data) = resp.result else {
      Issue.record("Expected success")
      return
    }
    #expect(data == nil)
  }

  @Test func errorResponseRoundtrip() throws {
    let frame = Messages.encodeErrorResponse(id: 4, message: "Not found", code: "NOT_FOUND")
    let msg = try Messages.decodeFrame(frame)
    guard case .response(let resp) = msg else {
      Issue.record("Expected response")
      return
    }
    #expect(resp.id == 4)
    guard case .remoteError(let message, let code, let errno) = resp.result else {
      Issue.record("Expected remoteError")
      return
    }
    #expect(message == "Not found")
    #expect(code == "NOT_FOUND")
    #expect(errno == 0)
  }

  // Frame prefix correctness: first 4 bytes must be little-endian body length
  @Test func framePrefixIsBodyLength() throws {
    let payload = Data([1, 2, 3])
    let frame = Messages.encodeRequest(id: 1, command: 0, data: payload)
    let bodyLen =
      UInt32(frame[0]) | (UInt32(frame[1]) << 8) | (UInt32(frame[2]) << 16)
      | (UInt32(frame[3]) << 24)
    #expect(Int(bodyLen) == frame.count - 4)
  }

  // Error response preserves errno value
  @Test func errorResponseErrnoRoundtrip() throws {
    let frame = Messages.encodeErrorResponse(id: 9, message: "fail", code: "ENOENT", errno: 42)
    let msg = try Messages.decodeFrame(frame)
    guard case .response(let resp) = msg else {
      Issue.record("Expected response")
      return
    }
    guard case .remoteError(let message, let code, let errno) = resp.result else {
      Issue.record("Expected remoteError")
      return
    }
    #expect(message == "fail")
    #expect(code == "ENOENT")
    #expect(errno == 42)
  }

  // Unknown message type returns nil (silently discarded)
  @Test func unknownMessageTypeReturnsNil() throws {
    var body = Data()
    body.append(99)  // type=99 (unknown)
    let frame = makeRawFrame(body)
    let result = try Messages.decodeFrame(frame)
    #expect(result == nil)
  }

  // Streaming request returns nil (silently discarded)
  @Test func streamingRequestReturnsNil() throws {
    var body = Data()
    body.append(1)  // type = 1 (request)
    body.append(5)  // id = 5
    body.append(1)  // command = 1
    body.append(1)  // stream = 1 (non-zero)
    body.append(0)  // data length = 0
    let frame = makeRawFrame(body)
    let result = try Messages.decodeFrame(frame)
    #expect(result == nil)
  }

  // Streaming response returns nil (silently discarded)
  @Test func streamingResponseReturnsNil() throws {
    var body = Data()
    body.append(2)  // type = 2 (response)
    body.append(5)  // id = 5
    body.append(0)  // error = false
    body.append(1)  // stream = 1 (non-zero)
    let frame = makeRawFrame(body)
    let result = try Messages.decodeFrame(frame)
    #expect(result == nil)
  }
}

/// Helper to build a raw frame from a body (prepends 4-byte LE length).
func makeRawFrame(_ body: Data) -> Data {
  let len = UInt32(body.count)
  var frame = Data(count: 4)
  frame[0] = UInt8(len & 0xFF)
  frame[1] = UInt8((len >> 8) & 0xFF)
  frame[2] = UInt8((len >> 16) & 0xFF)
  frame[3] = UInt8((len >> 24) & 0xFF)
  frame.append(body)
  return frame
}
