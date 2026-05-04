import Foundation

public class IncomingStream: AsyncSequence {
  public typealias Element = Data

  public let requestId: UInt
  public let mask: UInt
  public let highWaterMark: Int
  public let lowWaterMark: Int
  public private(set) var finished = false

  private weak var rpc: RPC?
  private var buffer: [Data] = []
  private var pendingError: Error?
  private var paused = false
  private var waiter: CheckedContinuation<Data?, Error>?
  private var iteratorMade = false

  init(requestId: UInt, mask: UInt, rpc: RPC, highWaterMark: Int = 16, lowWaterMark: Int = 4) {
    precondition(highWaterMark > 0 && lowWaterMark >= 0 && lowWaterMark < highWaterMark)
    self.requestId = requestId
    self.mask = mask
    self.rpc = rpc
    self.highWaterMark = highWaterMark
    self.lowWaterMark = lowWaterMark
  }

  func push(_ data: Data) {
    guard !finished else { return }
    if let waiter {
      self.waiter = nil
      waiter.resume(returning: data)
      return
    }
    buffer.append(data)
    if buffer.count >= highWaterMark && !paused {
      paused = true
      rpc?.sendData(Messages.encodeStream(id: requestId, flags: mask | StreamFlag.pause))
    }
  }

  func end() {
    guard !finished else { return }
    finished = true
    if let waiter {
      self.waiter = nil
      waiter.resume(returning: nil)
    }
    rpc?.removeIncomingStream(forId: requestId)
  }

  // Also emits DESTROY when called by the dispatcher on a remote CLOSE+ERROR (JS parity).
  public func destroy(error: RPCRemoteError? = nil) {
    guard !finished else { return }
    finished = true
    if let error {
      rpc?.sendData(
        Messages.encodeStream(
          id: requestId, flags: mask | StreamFlag.destroy | StreamFlag.error, error: error))
      if let waiter {
        self.waiter = nil
        waiter.resume(throwing: error)
      } else {
        pendingError = error
      }
    } else {
      rpc?.sendData(Messages.encodeStream(id: requestId, flags: mask | StreamFlag.destroy))
      if let waiter {
        self.waiter = nil
        waiter.resume(returning: nil)
      }
    }
    rpc?.removeIncomingStream(forId: requestId)
  }

  public func makeAsyncIterator() -> AsyncIterator {
    precondition(!iteratorMade, "IncomingStream is single-pass; iterate at most once")
    iteratorMade = true
    return AsyncIterator(stream: self)
  }

  public struct AsyncIterator: AsyncIteratorProtocol {
    let stream: IncomingStream

    public func next() async throws -> Data? {
      try await stream.nextChunk(isolation: nil)
    }

    // Preserves the caller's actor across the await so producer (push)
    // and consumer (nextChunk) share an executor — required for safe
    // single-isolation use without locks.
    public func next(isolation actor: isolated (any Actor)? = #isolation)
      async throws -> Data?
    {
      try await stream.nextChunk(isolation: actor)
    }
  }

  fileprivate func nextChunk(isolation actor: isolated (any Actor)? = #isolation)
    async throws -> Data?
  {
    if !buffer.isEmpty {
      let data = buffer.removeFirst()
      if buffer.count <= lowWaterMark && paused {
        paused = false
        rpc?.sendData(Messages.encodeStream(id: requestId, flags: mask | StreamFlag.resume))
      }
      return data
    }
    if let error = pendingError {
      pendingError = nil
      throw error
    }
    if finished {
      return nil
    }
    return try await withCheckedThrowingContinuation { cont in
      self.waiter = cont
    }
  }
}
