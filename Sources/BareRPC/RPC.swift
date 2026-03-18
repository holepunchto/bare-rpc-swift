// Sources/BareRPC/RPC.swift
import Foundation

/// Transport delegate for sending encoded frames over the wire.
///
/// Implement this protocol to connect ``RPC`` to any transport (TCP, WebSocket, IPC, etc.).
/// The delegate is held weakly by ``RPC`` to avoid retain cycles.
public protocol RPCDelegate: AnyObject {
  /// Called when the RPC instance has a framed message ready to send.
  ///
  /// - Parameters:
  ///   - rpc: The RPC instance that produced the data.
  ///   - data: A complete framed message (4-byte LE length prefix + compact-encoded body).
  func rpc(_ rpc: RPC, send data: Data)
}

/// Transport-agnostic RPC client/server.
///
/// `RPC` encodes outgoing requests and events, decodes incoming frames, and matches
/// responses to pending requests by ID. It is wire-compatible with the JavaScript
/// `bare-rpc` module and the C `librpc` library.
///
/// **Usage:**
/// 1. Create an `RPC` instance with a ``RPCDelegate`` that handles sending bytes.
/// 2. Set ``onRequest`` and/or ``onEvent`` to handle incoming messages.
/// 3. Call ``receive(_:)`` whenever the transport delivers bytes.
/// 4. Use ``request(_:data:)`` (async) or ``event(_:data:)`` (fire-and-forget) to send.
///
public class RPC {
  private var _buffer = Data()
  private var _nextId: UInt = 1
  private var _pending: [UInt: CheckedContinuation<Data?, Error>] = [:]

  /// The transport delegate responsible for sending framed data.
  public weak var delegate: RPCDelegate?

  /// Called when a tracked request (id > 0) is received from the remote peer.
  public var onRequest: ((IncomingRequest) async -> Void)?

  /// Called when a fire-and-forget event (id == 0) is received from the remote peer.
  public var onEvent: ((IncomingEvent) async -> Void)?

  /// Called when a malformed frame is received that cannot be decoded.
  ///
  /// Matches the JS reference behavior of `stream.destroy(err)` on decode failure.
  public var onError: ((Error) -> Void)?

  /// Creates a new RPC instance.
  ///
  /// - Parameters:
  ///   - delegate: The transport delegate for sending data. Held weakly.
  ///   - onRequest: Optional handler for incoming tracked requests.
  public init(delegate: RPCDelegate? = nil, onRequest: ((IncomingRequest) async -> Void)? = nil) {
    self.delegate = delegate
    self.onRequest = onRequest
  }

  // MARK: - Outgoing

  /// Send a tracked request and await the response.
  ///
  /// Allocates a unique request ID, encodes the request frame, sends it via the delegate,
  /// and suspends until the remote peer responds. The ID wraps at 2^32-1 to match the
  /// JS reference implementation.
  ///
  /// - Parameters:
  ///   - command: The application-defined command identifier.
  ///   - data: Optional payload bytes.
  /// - Returns: The response data, or nil if the remote replied with no data.
  /// - Throws: ``RPCRemoteError`` if the remote peer sent an error response.
  public func request(_ command: UInt, data: Data? = nil) async throws -> Data? {
    let id = _nextId
    _nextId = (_nextId % 0xFFFF_FFFE) + 1
    let frame = Messages.encodeRequest(id: id, command: command, data: data)
    return try await withCheckedThrowingContinuation { continuation in
      _pending[id] = continuation
      delegate?.rpc(self, send: frame)
    }
  }

  /// Send a fire-and-forget event (id == 0, no reply expected).
  ///
  /// - Parameters:
  ///   - command: The application-defined command identifier.
  ///   - data: Optional payload bytes.
  public func event(_ command: UInt, data: Data? = nil) {
    let frame = Messages.encodeEvent(command: command, data: data)
    delegate?.rpc(self, send: frame)
  }

  // MARK: - Incoming

  /// Feed received bytes from the transport.
  ///
  /// Buffers incoming data and extracts complete frames (4-byte LE length prefix + body).
  /// Each complete frame is dispatched to ``_processFrame(_:)`` in a separate `Task`.
  /// Handles partial delivery — call this with any chunk size.
  ///
  /// - Parameter data: Raw bytes from the transport.
  public func receive(_ data: Data) {
    _buffer.append(data)
    var frames: [Data] = []
    while _buffer.count >= 4 {
      let bodyLen = Int(
        UInt32(_buffer[_buffer.startIndex]) | (UInt32(_buffer[_buffer.startIndex + 1]) << 8)
          | (UInt32(_buffer[_buffer.startIndex + 2]) << 16)
          | (UInt32(_buffer[_buffer.startIndex + 3]) << 24)
      )
      let frameLen = 4 + bodyLen
      guard _buffer.count >= frameLen else { break }
      frames.append(Data(_buffer.prefix(frameLen)))
      _buffer.removeFirst(frameLen)
    }
    for frame in frames {
      _dispatchFrame(frame)
    }
  }

  // MARK: - Internal (used by IncomingRequest)

  /// Send a pre-encoded frame via the delegate. Used by ``IncomingRequest`` to send replies.
  func _sendData(_ data: Data) {
    delegate?.rpc(self, send: data)
  }

  // MARK: - Private

  /// Decode and dispatch a single complete frame synchronously.
  ///
  /// Responses are handled inline to avoid data races on ``_pending``.
  /// Requests and events are dispatched in a ``Task`` since their handlers are async.
  /// Streaming and unknown message types are silently discarded.
  /// Decode errors are reported via ``onError``.
  private func _dispatchFrame(_ frame: Data) {
    let message: DecodedMessage?
    do {
      message = try Messages.decodeFrame(frame)
    } catch {
      onError?(error)
      return
    }

    guard let message else { return }

    switch message {
    case .request(let req):
      Task { [weak self] in
        guard let self else { return }
        if req.id == 0 {
          let event = IncomingEvent(command: req.command, data: req.data)
          await self.onEvent?(event)
        } else {
          let incoming = IncomingRequest(
            id: req.id, command: req.command, data: req.data, rpc: self)
          await self.onRequest?(incoming)
        }
      }
    case .response(let resp):
      let continuation = _pending.removeValue(forKey: resp.id)
      if let continuation {
        switch resp.result {
        case .success(let data):
          continuation.resume(returning: data)
        case .remoteError(let msg, let code, let errno):
          continuation.resume(throwing: RPCRemoteError(message: msg, code: code, errno: errno))
        }
      }
    }
  }
}
