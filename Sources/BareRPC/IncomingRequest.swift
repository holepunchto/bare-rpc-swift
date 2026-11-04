import Foundation

/// A request of the peer, which is answered once with ``reply(_:)``,
/// ``reject(_:code:errno:)`` or ``createResponseStream()``. The body of a
/// streamed request is read once with ``createRequestStream()``.
// The mutable state is guarded by `lock`.
public final class IncomingRequest: @unchecked Sendable {
  public let command: UInt
  public let id: UInt
  public let data: Data?
  private weak var rpc: RPC?
  private var responseStream: OutgoingStream?
  private let unopenedRequestStream: IncomingStream?
  private let lock = NSLock()
  private var received = false
  private var answered = false

  /// Whether the request has been answered with ``reply(_:)``,
  /// ``reject(_:code:errno:)`` or ``createResponseStream()``. A request can
  /// only be answered once.
  public var sent: Bool { lock.withLock { answered } }

  /// Whether the request has a streamed body, which
  /// ``createRequestStream()`` returns.
  public var isStreamed: Bool { unopenedRequestStream != nil }

  /// Opens and returns the body of a streamed request, or returns `nil` if the
  /// request has none. The peer only starts sending the body once it has been
  /// opened.
  ///
  /// - Throws: `RPCError.alreadyReceived` if this has already been called.
  public func createRequestStream() async throws -> IncomingStream? {
    try lock.withLock {
      if received { throw RPCError.alreadyReceived("Request has already been received") }
      received = true
    }
    guard let stream = unopenedRequestStream else { return nil }
    await rpc?.openRequestStream(stream)
    return stream
  }

  init(id: UInt, command: UInt, data: Data?, rpc: RPC, requestStream: IncomingStream? = nil) {
    self.id = id
    self.command = command
    self.data = data
    self.rpc = rpc
    self.unopenedRequestStream = requestStream
  }

  /// - Throws: `RPCError.alreadySent` if the request has already been answered.
  public func reply(_ data: Data? = nil) async throws {
    try markSent()
    await rpc?.answer(id, Messages.encodeResponse(id: id, data: data))
  }

  /// - Throws: `RPCError.alreadySent` if the request has already been answered.
  public func reject(_ message: String, code: String = "", errno: Int = 0) async throws {
    try markSent()
    await rpc?.answer(
      id, Messages.encodeErrorResponse(id: id, message: message, code: code, errno: errno))
  }

  /// - Throws: `RPCError.alreadySent` if the request has already been answered,
  ///   or `RPCError.channelClosed` if the session no longer exists.
  public func createResponseStream() async throws -> OutgoingStream {
    try markSent()
    guard let rpc else { throw RPCError.channelClosed }
    let stream = OutgoingStream(requestId: id, mask: StreamFlag.response, rpc: rpc)
    lock.withLock { responseStream = stream }
    await rpc.registerResponseStream(
      stream, Messages.encodeResponse(id: id, stream: StreamFlag.open, data: nil))
    return stream
  }

  func rejectUnknownCommand() async throws {
    try await reject("Unknown command \(command)", code: "UNKNOWN_COMMAND", errno: 0)
  }

  func fail(_ error: Error) async {
    let error = RPCRemoteError(from: error)
    if let responseStream = lock.withLock({ responseStream }) {
      await responseStream.destroy(error: error)
    } else {
      try? await reject(error.message, code: error.code, errno: error.errno)
    }
  }

  private func markSent() throws {
    try lock.withLock {
      if answered { throw RPCError.alreadySent("Response has already been sent") }
      answered = true
    }
  }
}
