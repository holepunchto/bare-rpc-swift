// Tests/BareRPCTests/RPCErrorTests.swift
import Testing

@testable import BareRPC

@Suite struct RPCErrorTests {
  @Test func remoteErrorPreservesAllFields() {
    let error = RPCRemoteError(message: "not found", code: "ENOENT", errno: -2)
    #expect(error.message == "not found")
    #expect(error.code == "ENOENT")
    #expect(error.errno == -2)
    #expect(error is Error)
  }

  @Test func remoteErrorDefaultErrno() {
    let error = RPCRemoteError(message: "fail", code: "ERR")
    #expect(error.errno == 0)
  }
}
