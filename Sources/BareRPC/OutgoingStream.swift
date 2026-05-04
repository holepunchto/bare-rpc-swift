import Foundation

public actor OutgoingStream {
  public nonisolated let requestId: UInt
  public nonisolated let mask: UInt
  public private(set) var ended = false
  public private(set) var corked = false

  private weak var rpc: RPC?
  private var uncorkWaiters: [CheckedContinuation<Void, Never>] = []

  init(requestId: UInt, mask: UInt, rpc: RPC) {
    self.requestId = requestId
    self.mask = mask
    self.rpc = rpc
  }

  public func write(_ data: Data) async {
    guard !ended else { return }
    while corked {
      await suspendForUncork()
    }
    guard !ended else { return }
    await rpc?.sendData(
      Messages.encodeStream(id: requestId, flags: mask | StreamFlag.data, data: data))
  }

  public func end() async {
    guard !ended else { return }
    ended = true
    await rpc?.sendData(Messages.encodeStream(id: requestId, flags: mask | StreamFlag.end))
    await rpc?.sendData(Messages.encodeStream(id: requestId, flags: mask | StreamFlag.close))
    drainUncorkWaiters()
    await rpc?.removeOutgoingStream(forId: requestId)
  }

  public func destroy(error: RPCRemoteError? = nil) async {
    guard !ended else { return }
    ended = true
    if let error {
      await rpc?.sendData(
        Messages.encodeStream(
          id: requestId, flags: mask | StreamFlag.close | StreamFlag.error, error: error))
    } else {
      await rpc?.sendData(Messages.encodeStream(id: requestId, flags: mask | StreamFlag.close))
    }
    drainUncorkWaiters()
    await rpc?.removeOutgoingStream(forId: requestId)
  }

  func cork() {
    corked = true
  }

  func uncork() {
    guard corked else { return }
    corked = false
    drainUncorkWaiters()
  }

  private func drainUncorkWaiters() {
    let waiters = uncorkWaiters
    uncorkWaiters = []
    for cont in waiters {
      cont.resume()
    }
  }

  private func suspendForUncork() async {
    await withCheckedContinuation { cont in
      if !corked || ended {
        cont.resume()
      } else {
        uncorkWaiters.append(cont)
      }
    }
  }
}
