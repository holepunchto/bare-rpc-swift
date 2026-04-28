import Foundation

public class IncomingStream {
  public let requestId: UInt
  public let mask: UInt
  public let stream: AsyncThrowingStream<Data, Error>
  private let continuation: AsyncThrowingStream<Data, Error>.Continuation
  private weak var rpc: RPC?
  public private(set) var finished = false

  init(requestId: UInt, mask: UInt, rpc: RPC) {
    self.requestId = requestId
    self.mask = mask
    self.rpc = rpc
    var cont: AsyncThrowingStream<Data, Error>.Continuation!
    self.stream = AsyncThrowingStream<Data, Error> { cont = $0 }
    self.continuation = cont
  }

  func push(_ data: Data) {
    guard !finished else { return }
    continuation.yield(data)
  }

  func end() {
    guard !finished else { return }
    finished = true
    continuation.finish()
    rpc?.removeIncomingStream(forId: requestId)
  }

  public func destroy(error: RPCRemoteError? = nil) {
    guard !finished else { return }
    finished = true
    if let error {
      rpc?.sendData(
        Messages.encodeStream(
          id: requestId, flags: mask | StreamFlag.destroy | StreamFlag.error, error: error))
      continuation.finish(throwing: error)
    } else {
      rpc?.sendData(Messages.encodeStream(id: requestId, flags: mask | StreamFlag.destroy))
      continuation.finish()
    }
    rpc?.removeIncomingStream(forId: requestId)
  }
}
