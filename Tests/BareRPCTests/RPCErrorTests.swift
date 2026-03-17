// Tests/BareRPCTests/RPCErrorTests.swift
import Testing
@testable import BareRPC

@Suite struct RPCErrorTests {
  @Test func streamingNotSupportedIsError() {
    let error: any Error = RPCError.streamingNotSupported
    #expect(error is RPCError)
  }
}
