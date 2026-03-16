// Tests/BareRPCTests/RPCTests.swift
import XCTest
@testable import BareRPC

// In-memory transport: connects two RPC instances so bytes flow directly between them.
class PipeDelegate: RPCDelegate {
  weak var peer: RPC?
  public func rpc(_ rpc: RPC, send data: Data) {
    peer?.receive(data)
  }
}

final class RPCTests: XCTestCase {
  // Hold delegates strongly so they aren't deallocated — RPC.delegate is weak.
  private var delegateA: PipeDelegate?
  private var delegateB: PipeDelegate?

  func makePair(onRequest: ((IncomingRequest) async -> Void)? = nil) -> (RPC, RPC) {
    let da = PipeDelegate()
    let db = PipeDelegate()
    delegateA = da
    delegateB = db
    let a = RPC(delegate: da, onRequest: onRequest)
    let b = RPC(delegate: db, onRequest: onRequest)
    da.peer = b
    db.peer = a
    return (a, b)
  }

  // Basic request/response: client sends request, server replies, client gets the data back.
  func testRequestResponse() async throws {
    let (client, server) = makePair()

    server.onRequest = { req in
      // Echo the request data back as the response
      req.reply(req.data)
    }

    let payload = Data([1, 2, 3])
    let response = try await client.request(42, data: payload)
    XCTAssertEqual(response, payload)
  }

  // Server returns no data (nil reply).
  func testRequestWithNilResponse() async throws {
    let (client, server) = makePair()
    server.onRequest = { req in req.reply(nil) }
    let response = try await client.request(1, data: nil)
    XCTAssertNil(response)
  }

  // Server rejects the request: client receives an error.
  func testRequestRejection() async throws {
    let (client, server) = makePair()
    server.onRequest = { req in req.reject("Oops", code: "ERR") }
    do {
      _ = try await client.request(1, data: nil)
      XCTFail("Expected error")
    } catch {
      XCTAssertNotNil(error)
    }
  }

  // Fire-and-forget event: server receives it but does not reply.
  func testEvent() async throws {
    let received = expectation(description: "server receives event")
    let (client, server) = makePair()

    server.onRequest = { req in
      XCTAssertEqual(req.id, 0)          // events have id=0
      XCTAssertEqual(req.command, 7)
      XCTAssertEqual(req.data, Data([0xBE, 0xEF]))
      received.fulfill()
    }

    client.event(7, data: Data([0xBE, 0xEF]))
    await fulfillment(of: [received], timeout: 1)
  }

  // reply() on an event (id=0) must be a no-op, not crash.
  func testReplyOnEventIsNoop() async {
    let done = expectation(description: "handler called")
    let (client, _server) = makePair()

    _server.onRequest = { req in
      req.reply(Data([1]))   // should be a no-op
      done.fulfill()
    }

    client.event(1, data: nil)
    await fulfillment(of: [done], timeout: 1)
  }

  // Multiple concurrent requests are correctly tracked by ID.
  func testConcurrentRequests() async throws {
    let (client, server) = makePair()
    server.onRequest = { req in req.reply(req.data) }

    async let r1 = client.request(1, data: Data([1]))
    async let r2 = client.request(2, data: Data([2]))
    async let r3 = client.request(3, data: Data([3]))

    let results = try await [r1, r2, r3]
    XCTAssertEqual(results[0], Data([1]))
    XCTAssertEqual(results[1], Data([2]))
    XCTAssertEqual(results[2], Data([3]))
  }
}
