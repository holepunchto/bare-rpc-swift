import Foundation

/// Handles the requests and events that a ``CommandRouter`` has no handler for.
public protocol CommandRouterDelegate: AnyObject, Sendable {
  func commandRouter(
    _ router: CommandRouter, didReceiveUnknownRequest request: IncomingRequest) async throws
  func commandRouter(
    _ router: CommandRouter, didReceiveUnknownEvent event: IncomingEvent) async throws
}

extension CommandRouterDelegate {
  public func commandRouter(
    _ router: CommandRouter, didReceiveUnknownRequest request: IncomingRequest
  ) async throws {
    try await request.rejectUnknownCommand()
  }

  public func commandRouter(
    _ router: CommandRouter, didReceiveUnknownEvent event: IncomingEvent
  ) async throws {}
}

/// Routes incoming requests and events to per-command handlers.
///
/// Pass it as the `handler` of an ``RPC``. A request handler returns the data
/// to reply with, unless it has answered the request itself, and throwing
/// rejects the request. Commands without a handler go to the `delegate`, which by default
/// rejects unknown requests with `UNKNOWN_COMMAND` and drops unknown events.
// The handlers and the delegate are guarded by `lock`.
public final class CommandRouter: Handler, @unchecked Sendable {
  public typealias RequestHandler = @Sendable (IncomingRequest) async throws -> Data?
  public typealias EventHandler = @Sendable (IncomingEvent) async throws -> Void

  private let lock = NSLock()
  private var requestHandlers: [UInt: RequestHandler] = [:]
  private var eventHandlers: [UInt: EventHandler] = [:]
  private weak var storedDelegate: CommandRouterDelegate?

  public var delegate: CommandRouterDelegate? {
    get { lock.withLock { storedDelegate } }
    set { lock.withLock { storedDelegate = newValue } }
  }

  public init(delegate: CommandRouterDelegate? = nil) {
    self.storedDelegate = delegate
  }

  public func on(request command: UInt, _ handler: @escaping RequestHandler) {
    lock.withLock { requestHandlers[command] = handler }
  }

  public func on(event command: UInt, _ handler: @escaping EventHandler) {
    lock.withLock { eventHandlers[command] = handler }
  }

  /// Answers `request` with its handler.
  public func handle(_ request: IncomingRequest) async throws {
    guard let handler = lock.withLock({ requestHandlers[request.command] }) else {
      if let delegate {
        try await delegate.commandRouter(self, didReceiveUnknownRequest: request)
      } else {
        try await request.rejectUnknownCommand()
      }
      return
    }
    let data = try await handler(request)
    if !request.sent { try await request.reply(data) }
  }

  /// Delivers `event` to its handler.
  public func handle(_ event: IncomingEvent) async throws {
    if let handler = lock.withLock({ eventHandlers[event.command] }) {
      try await handler(event)
      return
    }
    try await delegate?.commandRouter(self, didReceiveUnknownEvent: event)
  }
}
