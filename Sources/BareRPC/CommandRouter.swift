import Foundation

/// Routes incoming requests and events to per-command handlers.
///
/// Plain composable object, not an `RPCDelegate` — adopters forward dispatch
/// from their own delegate methods. Request handlers return `Data?` to auto-reply;
/// throwing rejects. Unknown request commands are auto-rejected with
/// `ERR_UNKNOWN_COMMAND`. Unknown events fall through to `onUnknownEvent`.
public final class CommandRouter {
  public typealias RequestHandler = (IncomingRequest) async throws -> Data?
  public typealias EventHandler = (IncomingEvent) async -> Void

  private var requestHandlers: [UInt: RequestHandler] = [:]
  private var eventHandlers: [UInt: EventHandler] = [:]

  /// Called when an event arrives for a command with no registered handler.
  public var onUnknownEvent: EventHandler?

  public init() {}

  public func on(_ command: UInt, _ handler: @escaping RequestHandler) {
    requestHandlers[command] = handler
  }

  public func onEvent(_ command: UInt, _ handler: @escaping EventHandler) {
    eventHandlers[command] = handler
  }

  public func dispatch(_ request: IncomingRequest) async {
    guard let handler = requestHandlers[request.command] else {
      request.reject(
        "Unknown command \(request.command)", code: "ERR_UNKNOWN_COMMAND", errno: 0)
      return
    }
    do {
      let data = try await handler(request)
      request.reply(data)
    } catch let err as RPCRemoteError {
      request.reject(err.message, code: err.code, errno: err.errno)
    } catch {
      request.reject("Internal error", code: "ERROR", errno: 0)
    }
  }

  public func dispatch(_ event: IncomingEvent) async {
    if let handler = eventHandlers[event.command] {
      await handler(event)
    } else if let fallback = onUnknownEvent {
      await fallback(event)
    }
  }
}
