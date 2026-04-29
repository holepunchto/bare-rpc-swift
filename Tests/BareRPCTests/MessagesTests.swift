import CompactEncoding
import Foundation
import Testing

@testable import BareRPC

@Suite struct MessagesTests {

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

  @Test func framePrefixIsBodyLength() throws {
    let payload = Data([1, 2, 3])
    let frame = Messages.encodeRequest(id: 1, command: 0, data: payload)
    let bodyLen = readBodyLen(frame)
    #expect(Int(bodyLen) == frame.count - 4)
  }

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

  @Test func unknownMessageTypeReturnsNil() throws {
    var body = Data()
    body.append(99)
    let frame = makeRawFrame(body)
    let result = try Messages.decodeFrame(frame)
    #expect(result == nil)
  }

  @Test func requestWithNonZeroStreamDecodes() throws {
    var body = Data()
    body.append(1)  // type = 1 (request)
    body.append(5)  // id = 5
    body.append(1)  // command = 1
    body.append(1)  // stream = 1 (non-zero, no data field on wire)
    let frame = makeRawFrame(body)
    let result = try Messages.decodeFrame(frame)
    guard case .request(let req) = result else {
      Issue.record("Expected request")
      return
    }
    #expect(req.id == 5)
    #expect(req.stream == 1)
  }

  @Test func responseWithNonZeroStreamDecodes() throws {
    var body = Data()
    body.append(2)  // type = 2 (response)
    body.append(5)  // id = 5
    body.append(0)  // error = false
    body.append(1)  // stream = 1 (non-zero, no data field on wire)
    let frame = makeRawFrame(body)
    let result = try Messages.decodeFrame(frame)
    guard case .response(let resp) = result else {
      Issue.record("Expected response")
      return
    }
    #expect(resp.id == 5)
    #expect(resp.stream == 1)
  }
}

func makeRawFrame(_ body: Data) -> Data {
  var frame = makeRawHeader(claimingBodyLen: UInt32(body.count))
  frame.append(body)
  return frame
}

func makeRawHeader(claimingBodyLen len: UInt32) -> Data {
  var state = State()
  Primitive.UInt32().preencode(&state, len)
  state.allocate()
  try! Primitive.UInt32().encode(&state, len)
  return state.buffer
}

func readBodyLen(_ frame: Data) -> UInt32 {
  var state = State(frame)
  return try! Primitive.UInt32().decode(&state)
}
