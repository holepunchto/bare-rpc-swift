import Foundation

/// An error that is sent to or received from the peer, such as the rejection
/// of a request.
public struct RPCRemoteError: Error, Sendable, Equatable {
  public let message: String
  public let code: String
  public let errno: Int

  public init(message: String, code: String, errno: Int = 0) {
    self.message = message
    self.code = code
    self.errno = errno
  }

  // How a handler's error is sent to the peer: any other error carries its
  // description, with no code and errno 0, as in JS.
  init(from error: Error) {
    if let error = error as? RPCRemoteError {
      self = error
    } else {
      self.init(message: String(describing: error), code: "", errno: 0)
    }
  }
}

/// A failure of the session, or the misuse of a request.
public enum RPCError: Error, Sendable, Equatable {
  /// A frame of the peer was longer than `maxFrameSize`.
  case frameTooLarge(size: Int, limit: Int)
  /// A frame of the peer had a message type that this side does not know.
  case unknownMessage(type: UInt)
  /// A frame of the peer could not be decoded, or a valid peer could never
  /// have sent it.
  case invalidMessage(String)
  /// The transport ended, or the session was closed.
  case channelClosed
  /// The request has already been answered.
  case alreadySent(String)
  /// The reply, or the body of a streamed request, has already been read.
  case alreadyReceived(String)
  /// The peer answered a plain request with a stream. The request fails with
  /// this, and the stream of the peer is destroyed.
  case unexpectedStream
  /// The peer sent more data on an incoming stream than `maxBufferedBytes`
  /// without it being read, as it ignored the request to pause.
  case streamOverflow
  /// The peer did not answer the request within its timeout. The request is
  /// cancelled.
  case timeout
}
