// Sources/BareRPC/IncomingRequest.swift
import Foundation

/// Server-side handle for an incoming tracked request (id > 0).
public class IncomingRequest {
  public let command: UInt
  public let id: UInt
  public let data: Data?

  private weak var _rpc: RPC?

  init(id: UInt, command: UInt, data: Data?, rpc: RPC) {
    self.id = id
    self.command = command
    self.data = data
    self._rpc = rpc
  }

  /// Send a successful response.
  public func reply(_ data: Data? = nil) {
    guard let rpc = _rpc else { return }
    rpc._sendData(Messages.encodeResponse(id: id, data: data))
  }

  /// Send an error response.
  public func reject(_ message: String, code: String? = nil, errno: Int = 0) {
    guard let rpc = _rpc else { return }
    rpc._sendData(Messages.encodeErrorResponse(id: id, message: message, code: code ?? "ERROR", errno: errno))
  }
}
