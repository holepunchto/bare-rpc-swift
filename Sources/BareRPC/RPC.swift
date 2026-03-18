import CompactEncoding
import Foundation

public protocol RPCDelegate: AnyObject {
  func rpc(_ rpc: RPC, send data: Data)
}

public class RPC {
  private var _buffer = Data()
  private var _nextId: UInt = 1
  private var _pending: [UInt: CheckedContinuation<Data?, Error>] = [:]

  public weak var delegate: RPCDelegate?
  public var onRequest: ((IncomingRequest) async -> Void)?
  public var onEvent: ((IncomingEvent) async -> Void)?
  public var onError: ((Error) -> Void)?

  public init(delegate: RPCDelegate? = nil) {
    self.delegate = delegate
  }

  public func request(_ command: UInt, data: Data? = nil) async throws -> Data? {
    let id = _nextId
    _nextId = (_nextId % 0xFFFF_FFFE) + 1
    let frame = Messages.encodeRequest(id: id, command: command, data: data)
    return try await withCheckedThrowingContinuation { continuation in
      _pending[id] = continuation
      delegate?.rpc(self, send: frame)
    }
  }

  public func event(_ command: UInt, data: Data? = nil) {
    let frame = Messages.encodeEvent(command: command, data: data)
    delegate?.rpc(self, send: frame)
  }

  public func receive(_ data: Data) {
    _buffer.append(data)
    var frames: [Data] = []
    while _buffer.count >= 4 {
      var peekState = State(Data(_buffer.prefix(4)))
      let bodyLen = Int(try! Primitive.UInt32().decode(&peekState))
      let frameLen = 4 + bodyLen
      guard _buffer.count >= frameLen else { break }
      frames.append(Data(_buffer.prefix(frameLen)))
      _buffer.removeFirst(frameLen)
    }
    for frame in frames {
      _dispatchFrame(frame)
    }
  }

  func _sendData(_ data: Data) {
    delegate?.rpc(self, send: data)
  }

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
