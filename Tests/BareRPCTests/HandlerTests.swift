import Foundation
import Testing

@testable import BareRPC

@Suite struct HandlerTests {

  @Test func aHandlerOfRequestsOnlyDropsEvents() async throws {
    struct Echo: Handler {
      func handle(_ request: IncomingRequest) async throws {
        try await request.reply(request.data)
      }
    }

    let pair = RPCPair(serverHandler: Echo())

    await pair.client.event(1, data: Data([1]))
    #expect(try await pair.client.request(2, data: Data([2])) == Data([2]))
  }

  @Test func aHandlerOfEventsOnlyRejectsRequestsAsUnknown() async throws {
    struct Events: Handler {
      let confirm: Confirmation

      func handle(_ event: IncomingEvent) async throws {
        confirm()
      }
    }

    try await confirmation { confirm in
      let pair = RPCPair(serverHandler: Events(confirm: confirm))

      await pair.client.event(2)
      try await expectUnknownCommand { try await pair.client.request(1) }
    }
  }

  @Test func aSessionWithoutClosuresRejectsRequestsAsUnknownAndDropsEvents() async throws {
    let pair = RPCPair(server: { $0.rpcWithoutHandlers() })

    await pair.client.event(2)
    try await expectUnknownCommand { try await pair.client.request(1) }
    try await expectUnknownCommand { try await pair.client.request(3) }
  }

  private func expectUnknownCommand(_ request: () async throws -> Data?) async throws {
    do {
      _ = try await request()
      Issue.record("Expected UNKNOWN_COMMAND")
    } catch let error as RPCRemoteError {
      #expect(error.code == "UNKNOWN_COMMAND")
      #expect(error.errno == 0)
    }
  }
}
