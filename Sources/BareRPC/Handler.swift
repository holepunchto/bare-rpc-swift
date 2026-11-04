/// Answers the requests and receives the events of the peer of an ``RPC``.
///
/// Both requirements have default implementations, so a type can handle only
/// one kind. By default, requests are rejected with the code `UNKNOWN_COMMAND`
/// and events are dropped.
public protocol Handler: Sendable {
  /// Answers `request`. Throwing before the request has been answered rejects
  /// it with the error.
  func handle(_ request: IncomingRequest) async throws
  /// Receives `event`. Throwing fails the session.
  func handle(_ event: IncomingEvent) async throws
}

extension Handler {
  public func handle(_ request: IncomingRequest) async throws {
    try await request.rejectUnknownCommand()
  }

  public func handle(_ event: IncomingEvent) async throws {}
}
