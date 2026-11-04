import Foundation

/// The body of a request or response that this side sends to the peer.
public actor OutgoingStream {
  /// The id of the request that the stream belongs to.
  public nonisolated let requestId: UInt
  nonisolated let mask: UInt
  /// Whether the stream has been ended or destroyed, after which writes are
  /// dropped. Once the session has ended, writes throw its error instead.
  public var isEnded: Bool {
    if case .open = phase { return false }
    return true
  }
  /// Whether the peer has asked the stream to pause, which holds back writes.
  public private(set) var isCorked = false

  private enum Phase {
    case open
    case ending
    // Writes after `end()` are dropped, even if the session has since ended.
    case closed(failure: Error?, endCalled: Bool)
  }

  private var phase = Phase.open
  private weak var rpc: RPC?
  // Nothing but the OPEN is sent until the peer acks it, as a peer only
  // accepts data for a stream that it has opened.
  private var acknowledged = false
  private var writing = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  private var isClosed: Bool {
    if case .closed = phase { return true }
    return false
  }

  init(requestId: UInt, mask: UInt, rpc: RPC) {
    self.requestId = requestId
    self.mask = mask
    self.rpc = rpc
  }

  /// Writes `data` to the peer, once the peer has opened the stream and has
  /// not paused it.
  ///
  /// - Throws: The error that ended the session, if it ended before the data
  ///   was sent. A write after ``end()`` or ``destroy(error:)`` is dropped.
  public func write(_ data: Data) async throws {
    switch phase {
    case .open: break
    case .closed(let failure?, endCalled: false): throw failure
    default: return
    }
    writing += 1
    defer {
      writing -= 1
      if writing == 0 { wake() }
    }
    while (isCorked || !acknowledged) && !isClosed {
      await suspend()
    }
    if case .closed(let failure, _) = phase {
      if let failure { throw failure }
      return
    }
    await rpc?.sendAndWait(
      Messages.encodeStream(id: requestId, flags: mask | StreamFlag.data, data: data))
  }

  public func end() async {
    guard case .open = phase else { return }
    phase = .ending
    while (writing > 0 || !acknowledged) && !isClosed {
      await suspend()
    }
    guard !isClosed else { return }
    close(failure: nil)
    await rpc?.sendAndWait(Messages.encodeStream(id: requestId, flags: mask | StreamFlag.end))
    await rpc?.removeOutgoingStream(self)
  }

  public func destroy(error: RPCRemoteError? = nil) async {
    await destroy(error: error, waiting: true)
  }

  func destroy(error: RPCRemoteError?, waiting: Bool) async {
    guard !isClosed else { return }
    close(failure: nil)
    await rpc?.send(
      Messages.encodeStream(
        id: requestId, flags: mask | StreamFlag.close | (error == nil ? 0 : StreamFlag.error),
        error: error),
      waiting: waiting)
    await rpc?.removeOutgoingStream(self)
  }

  // Once the request is answered, a body that the peer never opened will
  // never be read, as in JS.
  func release(error: RPCRemoteError?) async {
    guard !acknowledged else { return }
    await destroy(error: error, waiting: false)
  }

  func abort(_ error: Error) {
    guard !isClosed else { return }
    close(failure: error)
  }

  private func close(failure: Error?) {
    let endCalled = if case .ending = phase { true } else { false }
    phase = .closed(failure: failure, endCalled: endCalled)
    wake()
  }

  func acknowledge() {
    acknowledged = true
    wake()
  }

  func cork() {
    isCorked = true
  }

  func uncork() {
    guard isCorked else { return }
    isCorked = false
    wake()
  }

  private func wake() {
    let waiters = self.waiters
    self.waiters = []
    for waiter in waiters {
      waiter.resume()
    }
  }

  private func suspend() async {
    await withCheckedContinuation { waiters.append($0) }
  }
}
