import Foundation
import Testing

@testable import BareRPC

private final class Gate: @unchecked Sendable {
  private let lock = NSLock()
  private var written: [Data] = []
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var open = false

  func write(_ data: Data) async {
    await withCheckedContinuation { continuation in
      let ready = lock.withLock {
        written.append(data)
        if !open { waiters.append(continuation) }
        return open
      }
      if ready { continuation.resume() }
    }
  }

  func release() {
    let waiters = lock.withLock {
      open = true
      defer { self.waiters = [] }
      return self.waiters
    }
    for waiter in waiters { waiter.resume() }
  }

  var frames: [Data] { lock.withLock { written } }
}

private func command(of frame: Data) -> UInt? {
  guard case .request(let req) = try? Messages.decodeFrame(frame) else { return nil }
  return req.command
}

@Suite struct TransportTests {

  @Test func writesAreAwaitedInOrder() async throws {
    let gate = Gate()
    let rpc = RPC(TestTransport { await gate.write($0) })

    let sent = Locked(false)
    let sending = Task {
      await rpc.event(1, data: Data([1]))
      await rpc.event(2, data: Data([2]))
      sent.value = true
    }

    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(!sent.value)
    #expect(gate.frames.count == 1)

    gate.release()
    await sending.value

    #expect(gate.frames.compactMap(command(of:)) == [1, 2])
  }

  @Test func aFailedWriteFailsTheSessionAndClosesTheTransport() async throws {
    struct Broken: Error {}

    let transport = TestTransport { _ in throw Broken() }
    let rpc = RPC(transport)

    await rpc.event(1)

    await #expect(throws: Broken.self) { try await rpc.wait() }
    await #expect(throws: Broken.self) { _ = try await rpc.request(1) }
    #expect(try await waitUntil { transport.isClosed })
  }

  @Test func closeStopsReadingAndClosesTheTransport() async throws {
    let requests = Locked(false)
    let transport = TestTransport()
    let rpc = RPC(transport, onRequest: { _ in requests.value = true })

    await rpc.close()
    #expect(transport.isClosed)

    await transport.input.feed(Messages.encodeRequest(id: 1, command: 1, data: nil))
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(!requests.value)
    try await rpc.wait()
  }

  @Test func closeWritesTheFramesAlreadySentFirst() async throws {
    let gate = Gate()
    let rpc = RPC(TestTransport { await gate.write($0) })

    let sending = Task { await rpc.event(1) }
    _ = try await waitUntil { !gate.frames.isEmpty }
    _ = try await rpc.createRequestStream(command: 2)
    let closing = Task { await rpc.close() }
    try await Task.sleep(nanoseconds: 50_000_000)

    gate.release()
    await closing.value
    await sending.value

    #expect(gate.frames.compactMap(command(of:)) == [1, 2])
  }

  @Test func theSessionEndsWithTheTransportAndClosesIt() async throws {
    let transport = TestTransport()
    let rpc = RPC(transport)

    await transport.input.finish()

    try await rpc.wait()
    do {
      _ = try await rpc.request(1)
      Issue.record("Expected channelClosed")
    } catch {
      guard case .channelClosed = error as? RPCError else {
        Issue.record("Expected channelClosed, got \(error)")
        return
      }
    }
    #expect(try await waitUntil { transport.isClosed })
  }
}
