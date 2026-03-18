import Testing

@testable import BareRPC

@Suite struct RPCErrorTests {
  @Test func remoteErrorDefaultErrno() {
    let error = RPCRemoteError(message: "fail", code: "ERR")
    #expect(error.errno == 0)
  }
}
