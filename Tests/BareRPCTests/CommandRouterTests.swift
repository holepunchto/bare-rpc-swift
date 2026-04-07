import Foundation
import Testing

@testable import BareRPC

@Suite struct CommandRouterTests {

  @Test func routesRequestToRegisteredHandler() async throws {
    let pair = RPCPair()
    let router = CommandRouter()
    router.on(7) { req in
      #expect(req.command == 7)
      return Data([0xAA]) + (req.data ?? Data())
    }
    pair.serverDelegate.onRequest = { req in await router.dispatch(req) }

    let response = try await pair.client.request(7, data: Data([0x01]))
    #expect(response == Data([0xAA, 0x01]))
  }

  @Test func unknownRequestCommandRejects() async throws {
    let pair = RPCPair()
    let router = CommandRouter()
    pair.serverDelegate.onRequest = { req in await router.dispatch(req) }

    do {
      _ = try await pair.client.request(99, data: nil)
      Issue.record("Expected rejection")
    } catch let err as RPCRemoteError {
      #expect(err.code == "ERR_UNKNOWN_COMMAND")
    }
  }

  @Test func handlerThrowingRPCRemoteErrorPropagates() async throws {
    let pair = RPCPair()
    let router = CommandRouter()
    router.on(1) { _ in
      throw RPCRemoteError(message: "nope", code: "EBAD", errno: -7)
    }
    pair.serverDelegate.onRequest = { req in await router.dispatch(req) }

    do {
      _ = try await pair.client.request(1, data: nil)
      Issue.record("Expected rejection")
    } catch let err as RPCRemoteError {
      #expect(err.message == "nope")
      #expect(err.code == "EBAD")
      #expect(err.errno == -7)
    }
  }

  @Test func handlerThrowingGenericErrorRejects() async throws {
    struct Boom: Error {}
    let pair = RPCPair()
    let router = CommandRouter()
    router.on(2) { _ in throw Boom() }
    pair.serverDelegate.onRequest = { req in await router.dispatch(req) }

    do {
      _ = try await pair.client.request(2, data: nil)
      Issue.record("Expected rejection")
    } catch let err as RPCRemoteError {
      #expect(err.code == "ERROR")
    }
  }

  @Test func routesEventToRegisteredHandler() async throws {
    let pair = RPCPair()
    let router = CommandRouter()

    try await confirmation { confirm in
      router.onEvent(5) { event in
        #expect(event.data == Data([0xBE]))
        confirm()
      }
      pair.serverDelegate.onEvent = { event in await router.dispatch(event) }

      pair.client.event(5, data: Data([0xBE]))
      try await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  @Test func unknownEventFallsThroughToOnUnknownEvent() async throws {
    let pair = RPCPair()
    let router = CommandRouter()

    try await confirmation { confirm in
      router.onUnknownEvent = { event in
        #expect(event.command == 123)
        confirm()
      }
      pair.serverDelegate.onEvent = { event in await router.dispatch(event) }

      pair.client.event(123, data: nil)
      try await Task.sleep(nanoseconds: 50_000_000)
    }
  }
}
