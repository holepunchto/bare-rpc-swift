// Sources/BareRPC/RPC.swift
import Foundation

public protocol RPCDelegate: AnyObject {
  func rpc(_ rpc: RPC, send data: Data)
}

public class RPC {
  public weak var delegate: RPCDelegate?
  public var onRequest: ((IncomingRequest) async -> Void)?

  private let _lock = NSLock()
  private var _buffer = Data()
  private var _nextId = 1
  private var _pending: [Int: CheckedContinuation<Data?, Error>] = [:]

  public init(delegate: RPCDelegate? = nil, onRequest: ((IncomingRequest) async -> Void)? = nil) {
    self.delegate = delegate
    self.onRequest = onRequest
  }

  // MARK: - Outgoing

  /// Send a tracked request and await the response.
  public func request(_ command: Int, data: Data? = nil) async throws -> Data? {
    let id: Int = _lock.withLock {
      let id = _nextId
      _nextId += 1
      return id
    }
    let frame = Messages.encodeRequest(id: id, command: command, data: data)
    return try await withCheckedThrowingContinuation { continuation in
      _lock.withLock { _pending[id] = continuation }
      delegate?.rpc(self, send: frame)
    }
  }

  /// Send a fire-and-forget event (id = 0, no reply expected).
  public func event(_ command: Int, data: Data? = nil) {
    let frame = Messages.encodeEvent(command: command, data: data)
    delegate?.rpc(self, send: frame)
  }

  // MARK: - Incoming

  /// Feed received bytes from the transport. Call this whenever your transport delivers data.
  public func receive(_ data: Data) {
    var frames: [Data] = []
    _lock.withLock {
      _buffer.append(data)
      while _buffer.count >= 4 {
        let bodyLen = Int(
          UInt32(_buffer[_buffer.startIndex]) |
          (UInt32(_buffer[_buffer.startIndex + 1]) << 8) |
          (UInt32(_buffer[_buffer.startIndex + 2]) << 16) |
          (UInt32(_buffer[_buffer.startIndex + 3]) << 24)
        )
        let frameLen = 4 + bodyLen
        guard _buffer.count >= frameLen else { break }
        frames.append(Data(_buffer.prefix(frameLen)))
        _buffer.removeFirst(frameLen)
      }
    }
    for frame in frames {
      Task { await self._processFrame(frame) }
    }
  }

  // MARK: - Internal (used by IncomingRequest)

  func _sendData(_ data: Data) {
    delegate?.rpc(self, send: data)
  }

  // MARK: - Private

  private func _processFrame(_ frame: Data) async {
    do {
      let message = try Messages.decodeFrame(frame)
      switch message {
      case .request(let req):
        let incoming = IncomingRequest(id: req.id, command: req.command, data: req.data, rpc: self)
        await onRequest?(incoming)
      case .response(let resp):
        let continuation = _lock.withLock { _pending.removeValue(forKey: resp.id) }
        if let continuation {
          switch resp.result {
          case .success(let data):
            continuation.resume(returning: data)
          case .remoteError(let msg, let code, _):
            let err = NSError(domain: code, code: 0, userInfo: [NSLocalizedDescriptionKey: msg])
            continuation.resume(throwing: err)
          case .streamingNotSupported:
            continuation.resume(throwing: RPCError.streamingNotSupported)
          }
        }
      }
    } catch let err as MessagesError {
      if case .streamingRequest(let id, _) = err, id > 0 {
        // Spec requires: send a rejection response for streaming requests with a tracked id
        let rejection = Messages.encodeErrorResponse(id: id, message: "Streaming not supported", code: "UNSUPPORTED")
        _sendData(rejection)
        // For id == 0 (streaming events), there is no id to reject — silently discard
      }
      // All other MessagesError cases (unknownMessageType, outOfBounds): discard, do not crash
    } catch {
      // Discard any other decode errors — do not crash
    }
  }
}

// Note: _buffer uses Data.removeFirst() which is O(n) per frame — acceptable for v1.
// For high-throughput production use, replace with an index-tracked circular buffer.
