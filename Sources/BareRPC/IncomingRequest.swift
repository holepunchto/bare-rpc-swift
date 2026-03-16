// Sources/BareRPC/IncomingRequest.swift
import Foundation

/// Server-side handle for an incoming request.
/// reply() and reject() are no-ops when id == 0 (fire-and-forget events).
public class IncomingRequest {
  public let command: Int
  public let id: Int
  public let data: Data?

  private weak var _rpc: RPC?

  init(id: Int, command: Int, data: Data?, rpc: RPC) {
    self.id = id
    self.command = command
    self.data = data
    self._rpc = rpc
  }

  /// Send a successful response. No-op when id == 0.
  public func reply(_ data: Data? = nil) {
    guard id > 0, let rpc = _rpc else { return }
    rpc._sendData(Messages.encodeResponse(id: id, data: data))
  }

  /// Send an error response. No-op when id == 0.
  public func reject(_ message: String, code: String? = nil) {
    guard id > 0, let rpc = _rpc else { return }
    rpc._sendData(Messages.encodeErrorResponse(id: id, message: message, code: code ?? "ERROR"))
  }
}
