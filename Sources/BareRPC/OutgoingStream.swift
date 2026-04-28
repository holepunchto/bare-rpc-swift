import Foundation

public class OutgoingStream {
  public let requestId: UInt
  public let mask: UInt
  private weak var rpc: RPC?
  public private(set) var ended = false

  init(requestId: UInt, mask: UInt, rpc: RPC) {
    self.requestId = requestId
    self.mask = mask
    self.rpc = rpc
  }

  public func write(_ data: Data) {
    guard !ended else { return }
    rpc?.sendData(Messages.encodeStream(id: requestId, flags: mask | StreamFlag.data, data: data))
  }

  public func end() {
    guard !ended else { return }
    ended = true
    rpc?.sendData(Messages.encodeStream(id: requestId, flags: mask | StreamFlag.end))
    rpc?.sendData(Messages.encodeStream(id: requestId, flags: mask | StreamFlag.close))
    rpc?.removeOutgoingStream(forId: requestId)
  }

  public func destroy(error: RPCRemoteError? = nil) {
    guard !ended else { return }
    ended = true
    if let error {
      rpc?.sendData(
        Messages.encodeStream(
          id: requestId, flags: mask | StreamFlag.close | StreamFlag.error, error: error))
    } else {
      rpc?.sendData(Messages.encodeStream(id: requestId, flags: mask | StreamFlag.close))
    }
    rpc?.removeOutgoingStream(forId: requestId)
  }
}
