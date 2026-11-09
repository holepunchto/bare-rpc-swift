import Foundation
import Testing

@testable import BareRPC

private let cancel = RPCRemoteError(message: "Gave up", code: "GAVE_UP", errno: 3)

@Suite(.timeLimit(.minutes(1))) struct CancellationTests {

  @Test func cancellingTheTaskCancelsTheHandler() async throws {
    let pair = RPCPair()
    let started = Locked(false)
    let observed = Locked<RPCRemoteError?>(nil)

    pair.serverSide.onRequest = { req in
      started.value = true
      do {
        try await Task.sleep(nanoseconds: 10_000_000_000)
      } catch {
        observed.value = req.cancellationError
        try await req.reply(Data("late".utf8))
      }
    }

    let task = Task { try await pair.client.request(1) }
    #expect(try await waitUntil { started.value })
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await waitUntil { observed.value != nil })
    #expect(observed.value?.code == "CANCELLED")
    #expect(pair.serverSide.sentResponses.isEmpty)
    #expect(await pair.server.trackedStateCount == 0)
  }

  @Test func timeoutCancelsTheRequest() async throws {
    let pair = RPCPair()
    let observed = Locked<RPCRemoteError?>(nil)

    pair.serverSide.onRequest = { req in
      try? await Task.sleep(nanoseconds: 10_000_000_000)
      observed.value = req.cancellationError
    }

    await #expect(throws: RPCError.timeout) {
      try await pair.client.request(1, timeout: 0.05)
    }
    #expect(try await waitUntil { observed.value != nil })
    #expect(observed.value?.code == "TIMEOUT")
  }

  @Test func aRequestOfACancelledTaskIsNeverSent() async throws {
    let pair = RPCPair()

    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await pair.client.request(1)
    }

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(pair.clientSide.sentFrames.isEmpty)
  }

  @Test func cancellingAStreamedRequestFailsTheStreamsOfBothEnds() async throws {
    let pair = RPCPair()
    let received = Locked<Error?>(nil)

    pair.serverSide.onRequest = { req in
      let body = try await req.createRequestStream()!
      do {
        for try await _ in body {}
      } catch {
        received.value = error
      }
    }

    let task = Task { try await pair.client.createBidirectionalStream(command: 1) }
    #expect(try await waitUntil { await pair.server.trackedStateCount > 0 })
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await waitUntil { received.value != nil })
    #expect((received.value as? RPCRemoteError)?.code == "CANCELLED")
    #expect(await pair.client.trackedStateCount == 0)
    #expect(await pair.server.trackedStateCount == 0)
  }

  @Test func aCancelledRequestIsNotAnswered() async throws {
    let peer = Capture()
    let rpc = peer.rpc()
    let streams = Locked<[OutgoingStream]>([])

    peer.onRequest = { req in
      try? await Task.sleep(nanoseconds: 10_000_000_000)
      if req.command == 1 { try await req.reply(nil) }
      if req.command == 2 { streams.append(try await req.createResponseStream()) }
      if req.command == 3 { try await req.reject("Nope") }
    }

    for id: UInt in 1...3 {
      await rpc.receive(Messages.encodeRequest(id: id, command: id, data: nil))
      await rpc.receive(Messages.encodeCancel(id: id, error: cancel))
    }

    #expect(try await waitUntil { streams.value.count == 1 })
    try await streams.value[0].write(Data([1]))
    #expect(await streams.value[0].isEnded)
    #expect(peer.sentFrames.isEmpty)
    #expect(await rpc.trackedStateCount == 0)
  }

  @Test func aCancelForAnUnknownRequestIsIgnored() async throws {
    let peer = Capture()
    let rpc = peer.rpc()
    peer.onRequest = { req in try await req.reply(nil) }

    await rpc.receive(Messages.encodeCancel(id: 7, error: cancel))
    let reply = Task { try await rpc.request(1) }
    await rpc.receive(Messages.encodeResponse(id: 1, data: Data([1])))

    #expect(try await reply.value == Data([1]))
  }

  @Test func closingTheSessionCancelsTheHandler() async throws {
    let pair = RPCPair()
    let started = Locked(false)
    let cancelled = Locked(false)

    pair.serverSide.onRequest = { _ in
      started.value = true
      try? await Task.sleep(nanoseconds: 10_000_000_000)
      cancelled.value = Task.isCancelled
    }

    let request = Task { try await pair.client.request(1) }
    #expect(try await waitUntil { started.value })
    await pair.server.close()

    #expect(try await waitUntil { cancelled.value })
    request.cancel()
  }
}
