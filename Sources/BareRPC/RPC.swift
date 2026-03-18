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
/// All mutable state is synchronized via `NSLock`. Properties (``delegate``, ``onRequest``,
/// ``onEvent``, ``onError``) are safe to read and write from any thread.
public class RPC {
  private let _lock = NSLock()
  private var _buffer = Data()
  private var _nextId: UInt = 1
  private var _pending: [UInt: CheckedContinuation<Data?, Error>] = [:]
  private weak var _delegate: RPCDelegate?
  private var _onRequest: ((IncomingRequest) async -> Void)?
  private var _onEvent: ((IncomingEvent) async -> Void)?
  private var _onError: ((Error) -> Void)?

  /// The transport delegate responsible for sending framed data.
  public weak var delegate: RPCDelegate? {
    get { _lock.withLock { _delegate } }
    set { _lock.withLock { _delegate = newValue } }
  }

  /// Called when a tracked request (id > 0) is received from the remote peer.
  public var onRequest: ((IncomingRequest) async -> Void)? {
    get { _lock.withLock { _onRequest } }
    set { _lock.withLock { _onRequest = newValue } }
  }

  /// Called when a fire-and-forget event (id == 0) is received from the remote peer.
  public var onEvent: ((IncomingEvent) async -> Void)? {
    get { _lock.withLock { _onEvent } }
    set { _lock.withLock { _onEvent = newValue } }
  }

  /// Called when a malformed frame is received that cannot be decoded.
  ///
  /// Matches the JS reference behavior of `stream.destroy(err)` on decode failure.
  public var onError: ((Error) -> Void)? {
    get { _lock.withLock { _onError } }
    set { _lock.withLock { _onError = newValue } }
  }

  /// Creates a new RPC instance.
  ///
  /// - Parameters:
  ///   - delegate: The transport delegate for sending data. Held weakly.
  ///   - onRequest: Optional handler for incoming tracked requests.
  public init(delegate: RPCDelegate? = nil, onRequest: ((IncomingRequest) async -> Void)? = nil) {
    self._delegate = delegate
    self._onRequest = onRequest
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
    let id: UInt = _lock.withLock {
      let id = _nextId
      _nextId = (_nextId % 0xFFFF_FFFE) + 1
      return id
    }
    let frame = Messages.encodeRequest(id: id, command: command, data: data)
    return try await withCheckedThrowingContinuation { continuation in
      _lock.withLock { _pending[id] = continuation }
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
    var frames: [Data] = []
    _lock.withLock {
      _buffer.append(data)
      while _buffer.count >= 4 {
        let bodyLen = Int(
          UInt32(_buffer[_buffer.startIndex]) | (UInt32(_buffer[_buffer.startIndex + 1]) << 8)
            | (UInt32(_buffer[_buffer.startIndex + 2]) << 16)
            | (UInt32(_buffer[_buffer.startIndex + 3]) << 24)
        )
        let frameLen = 4 + bodyLen
        guard _buffer.count >= frameLen else { break }
        frames.append(Data(_buffer.prefix(frameLen)))
        // Note: removeFirst is O(n) — acceptable for v1.
        // For high-throughput use, replace with an index-tracked buffer.
        _buffer.removeFirst(frameLen)
      }
    }
    for frame in frames {
      Task { await self._processFrame(frame) }
    }
  }

  // MARK: - Internal (used by IncomingRequest)

  /// Send a pre-encoded frame via the delegate. Used by ``IncomingRequest`` to send replies.
  func _sendData(_ data: Data) {
    delegate?.rpc(self, send: data)
  }

  // MARK: - Private

  /// Decode and dispatch a single complete frame.
  ///
  /// - Requests (id > 0) are dispatched to ``onRequest``.
  /// - Events (id == 0) are dispatched to ``onEvent``.
  /// - Responses are matched to pending continuations by ID.
  /// - Streaming and unknown message types are silently discarded.
  /// - Decode errors are reported via ``onError``.
  private func _processFrame(_ frame: Data) async {
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
      if req.id == 0 {
        let event = IncomingEvent(command: req.command, data: req.data)
        await onEvent?(event)
      } else {
        let incoming = IncomingRequest(id: req.id, command: req.command, data: req.data, rpc: self)
        await onRequest?(incoming)
      }
    case .response(let resp):
      let continuation = _lock.withLock { _pending.removeValue(forKey: resp.id) }
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
