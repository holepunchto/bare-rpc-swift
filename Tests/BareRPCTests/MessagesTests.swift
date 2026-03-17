// Tests/BareRPCTests/MessagesTests.swift
import Testing
@testable import BareRPC
import Foundation

@Suite struct MessagesTests {

  // --- Request encoding/decoding ---

  @Test func requestRoundtrip() throws {
    let payload = Data([1, 2, 3, 4])
    let frame = Messages.encodeRequest(id: 5, command: 1, data: payload)
    let msg = try Messages.decodeFrame(frame)
    guard case .request(let req) = msg else { Issue.record("Expected request"); return }
    #expect(req.id == 5)
    #expect(req.command == 1)
    #expect(req.data == payload)
  }

  @Test func eventRoundtrip() throws {
    let payload = Data([0xAB])
    let frame = Messages.encodeEvent(command: 2, data: payload)
    let msg = try Messages.decodeFrame(frame)
    guard case .request(let req) = msg else { Issue.record("Expected request"); return }
    #expect(req.id == 0)
    #expect(req.command == 2)
    #expect(req.data == payload)
  }

  @Test func requestWithNilData() throws {
    let frame = Messages.encodeRequest(id: 1, command: 3, data: nil)
    let msg = try Messages.decodeFrame(frame)
    guard case .request(let req) = msg else { Issue.record("Expected request"); return }
    #expect(req.data == nil)
  }

  // --- Response encoding/decoding ---

  @Test func successResponseRoundtrip() throws {
    let payload = Data([10, 20, 30])
    let frame = Messages.encodeResponse(id: 7, data: payload)
    let msg = try Messages.decodeFrame(frame)
    guard case .response(let resp) = msg else { Issue.record("Expected response"); return }
    #expect(resp.id == 7)
    guard case .success(let data) = resp.result else { Issue.record("Expected success"); return }
    #expect(data == payload)
  }

  @Test func successResponseWithNilData() throws {
    let frame = Messages.encodeResponse(id: 3, data: nil)
    let msg = try Messages.decodeFrame(frame)
    guard case .response(let resp) = msg else { Issue.record("Expected response"); return }
    guard case .success(let data) = resp.result else { Issue.record("Expected success"); return }
    #expect(data == nil)
  }

  @Test func errorResponseRoundtrip() throws {
    let frame = Messages.encodeErrorResponse(id: 4, message: "Not found", code: "NOT_FOUND")
    let msg = try Messages.decodeFrame(frame)
    guard case .response(let resp) = msg else { Issue.record("Expected response"); return }
    #expect(resp.id == 4)
    guard case .remoteError(let message, let code, _) = resp.result else {
      Issue.record("Expected remoteError"); return
    }
    #expect(message == "Not found")
    #expect(code == "NOT_FOUND")
  }

  // Frame prefix correctness: first 4 bytes must be little-endian body length
  @Test func framePrefixIsBodyLength() throws {
    let payload = Data([1, 2, 3])
    let frame = Messages.encodeRequest(id: 1, command: 0, data: payload)
    let bodyLen = UInt32(frame[0]) | (UInt32(frame[1]) << 8) | (UInt32(frame[2]) << 16) | (UInt32(frame[3]) << 24)
    #expect(Int(bodyLen) == frame.count - 4)
  }
}
