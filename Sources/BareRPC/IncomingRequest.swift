// Sources/BareRPC/IncomingRequest.swift
import Foundation

/// Server-side handle for an incoming tracked request (id > 0).
///
/// Provides ``reply(_:)`` and ``reject(_:code:errno:)`` to send a response back to the
/// requester. Each request should receive exactly one reply or rejection.
///
/// Holds a weak reference to the ``RPC`` instance to avoid retain cycles.
/// If the RPC instance is deallocated before a response is sent, reply/reject become no-ops.
public class IncomingRequest {
  /// The application-defined command identifier.
  public let command: UInt
  /// The unique request ID assigned by the sender.
  public let id: UInt
  /// The request payload, or nil if the sender provided no data.
  public let data: Data?

  private weak var _rpc: RPC?

  init(id: UInt, command: UInt, data: Data?, rpc: RPC) {
    self.id = id
    self.command = command
    self.data = data
    self._rpc = rpc
  }

  /// Send a successful response with optional data.
  ///
  /// - Parameter data: Optional response payload bytes.
  public func reply(_ data: Data? = nil) {
    guard let rpc = _rpc else { return }
    rpc._sendData(Messages.encodeResponse(id: id, data: data))
  }

  /// Send an error response.
  ///
  /// - Parameters:
  ///   - message: Human-readable error message.
  ///   - code: Machine-readable error code (defaults to "ERROR").
  ///   - errno: Numeric error number (defaults to 0).
  public func reject(_ message: String, code: String? = nil, errno: Int = 0) {
    guard let rpc = _rpc else { return }
    rpc._sendData(Messages.encodeErrorResponse(id: id, message: message, code: code ?? "ERROR", errno: errno))
  }
}
