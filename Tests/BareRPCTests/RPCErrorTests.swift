// Tests/BareRPCTests/RPCErrorTests.swift
import XCTest
@testable import BareRPC

final class RPCErrorTests: XCTestCase {
  func testMissingResponseIsError() {
    let error: Error = RPCError.missingResponse
    XCTAssertTrue(error is RPCError)
  }

  func testStreamingNotSupportedIsError() {
    let error: Error = RPCError.streamingNotSupported
    XCTAssertTrue(error is RPCError)
  }
}
