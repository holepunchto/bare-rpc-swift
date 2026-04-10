import Foundation

public class IncomingStream {
  public let requestId: UInt
  public let mask: UInt
  public let stream: AsyncThrowingStream<Data, Error>
  private let continuation: AsyncThrowingStream<Data, Error>.Continuation
  private let send: (Data) -> Void
  var onClose: (() -> Void)?
  private var finished = false

  public init(requestId: UInt, mask: UInt, send: @escaping (Data) -> Void) {
    self.requestId = requestId
    self.mask = mask
    self.send = send
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
    onClose?()
  }

  public func destroy(error: RPCRemoteError? = nil) {
    guard !finished else { return }
    finished = true
    if let error {
      send(
        Messages.encodeStream(
          id: requestId, flags: mask | StreamFlag.destroy | StreamFlag.error, error: error))
      continuation.finish(throwing: error)
    } else {
      send(Messages.encodeStream(id: requestId, flags: mask | StreamFlag.destroy))
      continuation.finish()
    }
    onClose?()
  }
}
