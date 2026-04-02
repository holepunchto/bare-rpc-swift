import CompactEncoding
import Foundation

public protocol RPCDelegate: AnyObject {
  func rpc(_ rpc: RPC, send data: Data)
}

public class RPC {
  private var buffer = Data()
  private var nextId: UInt = 1
  private var pending: [UInt: CheckedContinuation<Data?, Error>] = [:]

  public weak var delegate: RPCDelegate?
  public var onRequest: ((IncomingRequest) async -> Void)?
  public var onEvent: ((IncomingEvent) async -> Void)?
  public var onError: ((Error) -> Void)?

  public init(delegate: RPCDelegate? = nil) {
    self.delegate = delegate
  }

  public func request(_ command: UInt, data: Data? = nil) async throws -> Data? {
    let id = nextId
    nextId = (nextId % 0xFFFF_FFFE) + 1
    let frame = Messages.encodeRequest(id: id, command: command, data: data)
    return try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      delegate?.rpc(self, send: frame)
    }
  }

  public func event(_ command: UInt, data: Data? = nil) {
    let frame = Messages.encodeEvent(command: command, data: data)
    delegate?.rpc(self, send: frame)
  }

  public func receive(_ data: Data) {
    buffer.append(data)
    var frames: [Data] = []
    while buffer.count >= 4 {
      var peekState = State(Data(buffer.prefix(4)))
      let bodyLen = Int(try! Primitive.UInt32().decode(&peekState))
      let frameLen = 4 + bodyLen
      guard buffer.count >= frameLen else { break }
      frames.append(Data(buffer.prefix(frameLen)))
      buffer.removeFirst(frameLen)
    }
    for frame in frames {
      dispatchFrame(frame)
    }
  }

  func sendData(_ data: Data) {
    delegate?.rpc(self, send: data)
  }

  private func dispatchFrame(_ frame: Data) {
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
      guard req.stream == 0 else { return }
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
    case .stream:
      break
    case .response(let resp):
      guard resp.stream == 0 else { return }
      let continuation = pending.removeValue(forKey: resp.id)
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
