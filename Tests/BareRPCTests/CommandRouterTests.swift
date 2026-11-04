import Foundation
import Testing

@testable import BareRPC

@Suite struct CommandRouterTests {

  @Test func routesRequestToRegisteredHandler() async throws {
    let router = CommandRouter()
    router.on(request: 7) { req in
      #expect(req.command == 7)
      return Data([0xAA]) + (req.data ?? Data())
    }
    let pair = RPCPair(serverHandler: router)

    let response = try await pair.client.request(7, data: Data([0x01]))
    #expect(response == Data([0xAA, 0x01]))
  }

  @Test func unknownRequestCommandRejects() async throws {
    let pair = RPCPair(serverHandler: CommandRouter())

    do {
      _ = try await pair.client.request(99, data: nil)
      Issue.record("Expected rejection")
    } catch let err as RPCRemoteError {
      #expect(err.code == "UNKNOWN_COMMAND")
    }
  }

  @Test func handlerThrowingRPCRemoteErrorPropagates() async throws {
    let router = CommandRouter()
    router.on(request: 1) { _ in
      throw RPCRemoteError(message: "nope", code: "EBAD", errno: -7)
    }
    let pair = RPCPair(serverHandler: router)

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
    struct Boom: Error, CustomStringConvertible {
      var description: String { "boom" }
    }
    let router = CommandRouter()
    router.on(request: 2) { _ in throw Boom() }
    let pair = RPCPair(serverHandler: router)

    do {
      _ = try await pair.client.request(2, data: nil)
      Issue.record("Expected rejection")
    } catch let err as RPCRemoteError {
      #expect(err.message == "boom")
      #expect(err.code == "")
      #expect(err.errno == 0)
    }
  }

  @Test func routesEventToRegisteredHandler() async throws {
    let router = CommandRouter()
    let pair = RPCPair(serverHandler: router)

    try await confirmation { confirm in
      router.on(event: 5) { event in
        #expect(event.data == Data([0xBE]))
        confirm()
      }

      await pair.client.event(5, data: Data([0xBE]))
      try await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  @Test func unknownEventFallsThroughToDelegate() async throws {
    final class Captor: CommandRouterDelegate {
      let confirm: Confirmation
      init(confirm: Confirmation) { self.confirm = confirm }
      func commandRouter(
        _ router: CommandRouter, didReceiveUnknownEvent event: IncomingEvent
      ) async {
        #expect(event.command == 123)
        confirm()
      }
    }

    try await confirmation { confirm in
      let captor = Captor(confirm: confirm)
      let pair = RPCPair(serverHandler: CommandRouter(delegate: captor))

      await pair.client.event(123, data: nil)
      try await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  @Test func unknownRequestFallsThroughToDelegate() async throws {
    final class CustomReject: CommandRouterDelegate {
      func commandRouter(
        _ router: CommandRouter, didReceiveUnknownRequest request: IncomingRequest
      ) async throws {
        try await request.reject("custom miss", code: "ENOENT", errno: 2)
      }
    }

    let delegate = CustomReject()
    let pair = RPCPair(serverHandler: CommandRouter(delegate: delegate))

    do {
      _ = try await pair.client.request(99, data: nil)
      Issue.record("Expected rejection")
    } catch let err as RPCRemoteError {
      #expect(err.message == "custom miss")
      #expect(err.code == "ENOENT")
      #expect(err.errno == 2)
    }
  }

  @Test func unknownRequestWithDefaultDelegateStillRejects() async throws {
    // Delegate set but doesn't override the unknown-request method - protocol
    // extension default should still produce UNKNOWN_COMMAND.
    final class EmptyDelegate: CommandRouterDelegate {}

    let pair = RPCPair(serverHandler: CommandRouter(delegate: EmptyDelegate()))

    do {
      _ = try await pair.client.request(99, data: nil)
      Issue.record("Expected rejection")
    } catch let err as RPCRemoteError {
      #expect(err.code == "UNKNOWN_COMMAND")
    }
  }

  @Test func unknownEventWithDefaultDelegateIsNoop() async throws {
    // Delegate set but doesn't override didReceiveUnknownEvent - protocol
    // extension default is a silent no-op.
    final class EmptyDelegate: CommandRouterDelegate {}

    let pair = RPCPair()
    let router = CommandRouter(delegate: EmptyDelegate())

    try await confirmation { confirm in
      pair.serverSide.onEvent = { event in
        try await router.handle(event)
        confirm()
      }
      await pair.client.event(99, data: nil)
      try await Task.sleep(nanoseconds: 50_000_000)
    }
  }
}
