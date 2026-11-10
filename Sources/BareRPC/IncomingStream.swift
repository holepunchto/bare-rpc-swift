import Foundation

/// The body of a request or response that the peer sends, read by iterating
/// it.
///
/// Cancelling the task that waits for the next chunk makes the iteration throw
/// `CancellationError`. For the reply of a request of this side, it also
/// cancels the request, unless the reply has already ended. The body of a
/// request of the peer is left as it is and can still be read.
public actor IncomingStream: AsyncSequence {
  public typealias Element = Data

  /// The id of the request that the stream belongs to.
  public nonisolated let requestId: UInt
  nonisolated let mask: UInt
  /// The number of buffered bytes at which the peer is asked to pause. It is
  /// asked to resume once fewer bytes than this are buffered.
  public nonisolated let highWaterMark: Int
  /// Whether the peer has ended the stream or it has been destroyed. Chunks
  /// that are already buffered can still be read.
  public private(set) var isFinished = false

  // The default of the JS streams of bare-rpc, which bare-stream inherits from streamx.
  static let defaultHighWaterMark = 16384

  private weak var rpc: RPC?
  // Chunks before `head` have been read, and are dropped once they make up
  // half of the buffer, so that each read is amortized O(1).
  private var buffer: [Data] = []
  private var head = 0
  private var bufferedBytes = 0
  private var pendingError: Error?
  private var paused = false
  private var waiter: CheckedContinuation<Data?, Error>?
  // Counts the waits for a chunk, so that a late cancellation of one wait
  // can't end a later one.
  private var waits = 0

  init(
    requestId: UInt, mask: UInt, rpc: RPC,
    highWaterMark: Int = IncomingStream.defaultHighWaterMark
  ) {
    precondition(highWaterMark > 0)
    self.requestId = requestId
    self.mask = mask
    self.rpc = rpc
    self.highWaterMark = highWaterMark
  }

  /// Returns the number of bytes buffered and not yet read.
  @discardableResult
  func push(_ data: Data) async -> Int {
    guard !isFinished else { return bufferedBytes }
    if let waiter {
      self.waiter = nil
      waiter.resume(returning: data)
      return bufferedBytes
    }
    buffer.append(data)
    bufferedBytes += data.count
    if bufferedBytes >= highWaterMark && !paused {
      paused = true
      rpc?.queue(Messages.encodeStream(id: requestId, flags: mask | StreamFlag.pause))
    }
    return bufferedBytes
  }

  func end() async {
    guard !isFinished else { return }
    isFinished = true
    finishReader()
    await rpc?.removeIncomingStream(self)
  }

  func abort(_ error: Error) {
    guard !isFinished else { return }
    isFinished = true
    throwToReader(error)
  }

  private func throwToReader(_ error: Error) {
    if let waiter {
      self.waiter = nil
      waiter.resume(throwing: error)
    } else {
      pendingError = error
    }
  }

  private func finishReader() {
    guard let waiter else { return }
    self.waiter = nil
    waiter.resume(returning: nil)
  }

  public func destroy(error: RPCRemoteError? = nil) async {
    await destroy(error: error, waiting: true)
  }

  // A CLOSE with an error from the peer also destroys the stream, which sends
  // DESTROY back, as in JS.
  func destroy(error: RPCRemoteError?, waiting: Bool) async {
    guard !isFinished else { return }
    isFinished = true
    if let error {
      // Hand the error to the consumer before sending, which suspends: a reader
      // entering during that await would otherwise see the stream finished with no pending
      // error and end the sequence cleanly, losing the error.
      throwToReader(error)
      await rpc?.send(
        Messages.encodeStream(
          id: requestId, flags: mask | StreamFlag.destroy | StreamFlag.error, error: error),
        waiting: waiting)
    } else {
      await rpc?.send(
        Messages.encodeStream(id: requestId, flags: mask | StreamFlag.destroy), waiting: waiting)
      finishReader()
    }
    await rpc?.removeIncomingStream(self)
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
    if head < buffer.count {
      let data = buffer[head]
      head += 1
      if head * 2 >= buffer.count {
        buffer.removeFirst(head)
        head = 0
      }
      bufferedBytes -= data.count
      if bufferedBytes < highWaterMark && paused && !isFinished {
        paused = false
        rpc?.queue(Messages.encodeStream(id: requestId, flags: mask | StreamFlag.resume))
      }
      return data
    }
    if let error = pendingError {
      pendingError = nil
      throw error
    }
    if isFinished {
      return nil
    }
    waits += 1
    let wait = waits
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { cont in
        self.waiter = cont
      }
    } onCancel: {
      Task { await self.cancelWait(wait) }
    }
  }

  private func cancelWait(_ wait: Int) async {
    guard wait == waits, let waiter else { return }
    self.waiter = nil
    if mask == StreamFlag.response {
      isFinished = true
      await rpc?.cancelResponseStream(self)
    }
    waiter.resume(throwing: CancellationError())
  }
}
