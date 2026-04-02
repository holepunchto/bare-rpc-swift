import Foundation

public class OutgoingStream {
  public let requestId: UInt
  public let mask: UInt
  private let _send: (Data) -> Void
  private var _ended = false

  public init(requestId: UInt, mask: UInt, send: @escaping (Data) -> Void) {
    self.requestId = requestId
    self.mask = mask
    self._send = send
  }

  public func write(_ data: Data) {
    guard !_ended else { return }
    _send(Messages.encodeStream(id: requestId, flags: mask | StreamFlag.data, data: data))
  }

  public func end() {
    guard !_ended else { return }
    _ended = true
    _send(Messages.encodeStream(id: requestId, flags: mask | StreamFlag.end))
    _send(Messages.encodeStream(id: requestId, flags: mask | StreamFlag.close))
  }

  public func destroy(error: RPCRemoteError? = nil) {
    guard !_ended else { return }
    _ended = true
    if let error {
      _send(
        Messages.encodeStream(
          id: requestId, flags: mask | StreamFlag.close | StreamFlag.error, error: error))
    } else {
      _send(Messages.encodeStream(id: requestId, flags: mask | StreamFlag.close))
    }
  }
}
