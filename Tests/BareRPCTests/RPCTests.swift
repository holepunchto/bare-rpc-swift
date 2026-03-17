// Tests/BareRPCTests/RPCTests.swift
import Testing
@testable import BareRPC
import Foundation

// In-memory transport: connects two RPC instances so bytes flow directly between them.
class PipeDelegate: RPCDelegate {
  weak var peer: RPC?
  public func rpc(_ rpc: RPC, send data: Data) {
    peer?.receive(data)
  }
}

func makePair(onRequest: ((IncomingRequest) async -> Void)? = nil) -> (client: RPC, server: RPC, delegates: (PipeDelegate, PipeDelegate)) {
  let da = PipeDelegate()
  let db = PipeDelegate()
  let a = RPC(delegate: da, onRequest: onRequest)
  let b = RPC(delegate: db, onRequest: onRequest)
  da.peer = b
  db.peer = a
  return (a, b, (da, db))
}

@Suite struct RPCTests {

  // Basic request/response: client sends request, server replies, client gets the data back.
  @Test func requestResponse() async throws {
    let (client, server, _delegates) = makePair()

    server.onRequest = { req in
      req.reply(req.data)
    }

    let payload = Data([1, 2, 3])
    let response = try await client.request(42, data: payload)
    #expect(response == payload)
  }

  // Server returns no data (nil reply).
  @Test func requestWithNilResponse() async throws {
    let (client, server, _delegates) = makePair()
    server.onRequest = { req in req.reply(nil) }
    let response = try await client.request(1, data: nil)
    #expect(response == nil)
  }

  // Server rejects the request: client receives an error.
  @Test func requestRejection() async throws {
    let (client, server, _delegates) = makePair()
    server.onRequest = { req in req.reject("Oops", code: "ERR") }
    await #expect(throws: (any Error).self) {
      _ = try await client.request(1, data: nil)
    }
  }

  // Fire-and-forget event: server receives it but does not reply.
  @Test func event() async throws {
    let (client, server, _delegates) = makePair()

    try await confirmation { confirm in
      server.onRequest = { req in
        #expect(req.id == 0)
        #expect(req.command == 7)
        #expect(req.data == Data([0xBE, 0xEF]))
        confirm()
      }

      client.event(7, data: Data([0xBE, 0xEF]))
      try await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  // reply() on an event (id=0) must be a no-op, not crash.
  @Test func replyOnEventIsNoop() async throws {
    let (client, server, _delegates) = makePair()

    try await confirmation { confirm in
      server.onRequest = { req in
        req.reply(Data([1]))   // should be a no-op
        confirm()
      }

      client.event(1, data: nil)
      try await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  // Multiple concurrent requests are correctly tracked by ID.
  @Test func concurrentRequests() async throws {
    let (client, server, _delegates) = makePair()
    server.onRequest = { req in req.reply(req.data) }

    async let r1 = client.request(1, data: Data([1]))
    async let r2 = client.request(2, data: Data([2]))
    async let r3 = client.request(3, data: Data([3]))

    let results = try await [r1, r2, r3]
    #expect(results[0] == Data([1]))
    #expect(results[1] == Data([2]))
    #expect(results[2] == Data([3]))
  }
}
