import Foundation

/// An event of the peer, which gets no reply.
public struct IncomingEvent: Sendable {
  public let command: UInt
  public let data: Data?
}
