import Foundation

public actor IncomingStream: AsyncSequence {
  public typealias Element = Data

  public nonisolated let requestId: UInt
  public nonisolated let mask: UInt
  public nonisolated let highWaterMark: Int
  public nonisolated let lowWaterMark: Int
  public private(set) var finished = false

  private weak var rpc: RPC?
  private var buffer: [Data] = []
  private var pendingError: Error?
  private var paused = false
  private var waiter: CheckedContinuation<Data?, Error>?

  init(requestId: UInt, mask: UInt, rpc: RPC, highWaterMark: Int = 16, lowWaterMark: Int = 4) {
    precondition(highWaterMark > 0 && lowWaterMark >= 0 && lowWaterMark < highWaterMark)
    self.requestId = requestId
    self.mask = mask
    self.rpc = rpc
    self.highWaterMark = highWaterMark
    self.lowWaterMark = lowWaterMark
  }

  func push(_ data: Data) async {
    guard !finished else { return }
    if let waiter {
      self.waiter = nil
      waiter.resume(returning: data)
      return
    }
    buffer.append(data)
    if buffer.count >= highWaterMark && !paused {
      paused = true
      await rpc?.sendData(Messages.encodeStream(id: requestId, flags: mask | StreamFlag.pause))
    }
  }

  func end() async {
    guard !finished else { return }
    finished = true
    if let waiter {
      self.waiter = nil
      waiter.resume(returning: nil)
    }
    await rpc?.removeIncomingStream(forId: requestId)
  }

  // Also emits DESTROY when called by the dispatcher on a remote CLOSE+ERROR (JS parity).
  public func destroy(error: RPCRemoteError? = nil) async {
    guard !finished else { return }
    finished = true
    if let error {
      await rpc?.sendData(
        Messages.encodeStream(
          id: requestId, flags: mask | StreamFlag.destroy | StreamFlag.error, error: error))
      if let waiter {
        self.waiter = nil
        waiter.resume(throwing: error)
      } else {
        pendingError = error
      }
    } else {
      await rpc?.sendData(Messages.encodeStream(id: requestId, flags: mask | StreamFlag.destroy))
      if let waiter {
        self.waiter = nil
        waiter.resume(returning: nil)
      }
    }
    await rpc?.removeIncomingStream(forId: requestId)
  }

  public nonisolated func makeAsyncIterator() -> AsyncIterator {
    return AsyncIterator(stream: self)
  }

  public struct AsyncIterator: AsyncIteratorProtocol {
    let stream: IncomingStream

    public func next() async throws -> Data? {
      try await stream.nextChunk()
    }

    public func next(isolation actor: isolated (any Actor)? = #isolation)
      async throws -> Data?
    {
      try await stream.nextChunk()
    }
  }

  fileprivate func nextChunk() async throws -> Data? {
    precondition(waiter == nil, "IncomingStream does not support concurrent iteration")
    if !buffer.isEmpty {
      let data = buffer.removeFirst()
      if buffer.count <= lowWaterMark && paused {
        paused = false
        await rpc?.sendData(Messages.encodeStream(id: requestId, flags: mask | StreamFlag.resume))
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
