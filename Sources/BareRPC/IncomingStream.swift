import Foundation

public class IncomingStream {
  public let requestId: UInt
  public let mask: UInt
  public let stream: AsyncThrowingStream<Data, Error>
  private let _continuation: AsyncThrowingStream<Data, Error>.Continuation
  private var _finished = false

  public init(requestId: UInt, mask: UInt) {
    self.requestId = requestId
    self.mask = mask
    var cont: AsyncThrowingStream<Data, Error>.Continuation!
    self.stream = AsyncThrowingStream<Data, Error> { cont = $0 }
    self._continuation = cont
  }

  func push(_ data: Data) {
    guard !_finished else { return }
    _continuation.yield(data)
  }

  func end() {
    guard !_finished else { return }
    _finished = true
    _continuation.finish()
  }

  public func destroy(error: RPCRemoteError? = nil) {
    guard !_finished else { return }
    _finished = true
    if let error {
      _continuation.finish(throwing: error)
    } else {
      _continuation.finish()
    }
  }
}
