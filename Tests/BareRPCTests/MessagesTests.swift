// Tests/BareRPCTests/MessagesTests.swift
import XCTest
@testable import BareRPC

final class MessagesTests: XCTestCase {

  // --- Request encoding/decoding ---

  func testRequestRoundtrip() throws {
    let payload = Data([1, 2, 3, 4])
    let frame = Messages.encodeRequest(id: 5, command: 1, data: payload)
    let msg = try Messages.decodeFrame(frame)
    guard case .request(let req) = msg else { XCTFail("Expected request"); return }
    XCTAssertEqual(req.id, 5)
    XCTAssertEqual(req.command, 1)
    XCTAssertEqual(req.data, payload)
  }

  func testEventRoundtrip() throws {
    let payload = Data([0xAB])
    let frame = Messages.encodeEvent(command: 2, data: payload)
    let msg = try Messages.decodeFrame(frame)
    guard case .request(let req) = msg else { XCTFail("Expected request"); return }
    XCTAssertEqual(req.id, 0)    // id=0 is fire-and-forget
    XCTAssertEqual(req.command, 2)
    XCTAssertEqual(req.data, payload)
  }

  func testRequestWithNilData() throws {
    let frame = Messages.encodeRequest(id: 1, command: 3, data: nil)
    let msg = try Messages.decodeFrame(frame)
    guard case .request(let req) = msg else { XCTFail("Expected request"); return }
    XCTAssertNil(req.data)
  }

  // --- Response encoding/decoding ---

  func testSuccessResponseRoundtrip() throws {
    let payload = Data([10, 20, 30])
    let frame = Messages.encodeResponse(id: 7, data: payload)
    let msg = try Messages.decodeFrame(frame)
    guard case .response(let resp) = msg else { XCTFail("Expected response"); return }
    XCTAssertEqual(resp.id, 7)
    guard case .success(let data) = resp.result else { XCTFail("Expected success"); return }
    XCTAssertEqual(data, payload)
  }

  func testSuccessResponseWithNilData() throws {
    let frame = Messages.encodeResponse(id: 3, data: nil)
    let msg = try Messages.decodeFrame(frame)
    guard case .response(let resp) = msg else { XCTFail("Expected response"); return }
    guard case .success(let data) = resp.result else { XCTFail("Expected success"); return }
    XCTAssertNil(data)
  }

  func testErrorResponseRoundtrip() throws {
    let frame = Messages.encodeErrorResponse(id: 4, message: "Not found", code: "NOT_FOUND")
    let msg = try Messages.decodeFrame(frame)
    guard case .response(let resp) = msg else { XCTFail("Expected response"); return }
    XCTAssertEqual(resp.id, 4)
    guard case .remoteError(let message, let code, _) = resp.result else {
      XCTFail("Expected remoteError"); return
    }
    XCTAssertEqual(message, "Not found")
    XCTAssertEqual(code, "NOT_FOUND")
  }

  // Frame prefix correctness: first 4 bytes must be little-endian body length
  func testFramePrefixIsBodyLength() throws {
    let payload = Data([1, 2, 3])
    let frame = Messages.encodeRequest(id: 1, command: 0, data: payload)
    let bodyLen = UInt32(frame[0]) | (UInt32(frame[1]) << 8) | (UInt32(frame[2]) << 16) | (UInt32(frame[3]) << 24)
    XCTAssertEqual(Int(bodyLen), frame.count - 4)
  }
}
