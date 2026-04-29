import CompactEncoding
import Foundation

public protocol RPCDelegate: AnyObject {
  func rpc(_ rpc: RPC, send data: Data)
  func rpc(_ rpc: RPC, didReceiveRequest request: IncomingRequest) async throws
  func rpc(_ rpc: RPC, didReceiveEvent event: IncomingEvent) async
  func rpc(_ rpc: RPC, didFailWith error: Error)
}

extension RPCDelegate {
  public func rpc(_ rpc: RPC, didReceiveRequest request: IncomingRequest) async throws {}
  public func rpc(_ rpc: RPC, didReceiveEvent event: IncomingEvent) async {}
  public func rpc(_ rpc: RPC, didFailWith error: Error) {}
}

public class RPC {
  public let maxFrameSize: Int

  private var buffer = Data()
  private var nextId: UInt = 1
  private var pending: [UInt: CheckedContinuation<Data?, Error>] = [:]
  private var pendingResponseStreams: [UInt: CheckedContinuation<IncomingStream, Error>] = [:]
  private var incomingStreams: [UInt: IncomingStream] = [:]
  private var outgoingStreams: [UInt: OutgoingStream] = [:]
  private var failed = false
  private var failureError: Error?

  public weak var delegate: RPCDelegate?

  public init(delegate: RPCDelegate? = nil, maxFrameSize: Int = 16 * 1024 * 1024) {
    self.delegate = delegate
    self.maxFrameSize = maxFrameSize
  }

  public func request(_ command: UInt, data: Data? = nil) async throws -> Data? {
    if let failureError { throw failureError }
    let id = nextId
    nextId = (nextId % 0xFFFF_FFFE) + 1
    let frame = Messages.encodeRequest(id: id, command: command, data: data)
    return try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      delegate?.rpc(self, send: frame)
    }
  }

  public func event(_ command: UInt, data: Data? = nil) {
    guard !failed else { return }
    let frame = Messages.encodeEvent(command: command, data: data)
    delegate?.rpc(self, send: frame)
  }

  public func createRequestStream(command: UInt) throws -> OutgoingStream {
    if let failureError { throw failureError }
    let id = nextId
    nextId = (nextId % 0xFFFF_FFFE) + 1
    let stream = OutgoingStream(requestId: id, mask: StreamFlag.request, rpc: self)
    registerOutgoingStream(stream, forId: id)
    // Send OPEN handshake: type=REQUEST with stream=OPEN
    sendData(Messages.encodeRequest(id: id, command: command, stream: StreamFlag.open, data: nil))
    return stream
  }

  public func requestWithResponseStream(command: UInt, data: Data? = nil) async throws
    -> IncomingStream
  {
    if let failureError { throw failureError }
    let id = nextId
    nextId = (nextId % 0xFFFF_FFFE) + 1
    let frame = Messages.encodeRequest(id: id, command: command, data: data)
    return try await withCheckedThrowingContinuation { continuation in
      pendingResponseStreams[id] = continuation
      delegate?.rpc(self, send: frame)
    }
  }

  public func receive(_ data: Data) {
    guard !failed else { return }
    buffer.append(data)
    var frames: [Data] = []
    var oversize: (size: Int, limit: Int)?
    while buffer.count >= 4 {
      var peekState = State(Data(buffer.prefix(4)))
      let bodyLen = Int(try! Primitive.UInt32().decode(&peekState))
      let frameLen = 4 + bodyLen
      if frameLen > maxFrameSize {
        oversize = (frameLen, maxFrameSize)
        break
      }
      guard buffer.count >= frameLen else { break }
      frames.append(Data(buffer.prefix(frameLen)))
      buffer.removeFirst(frameLen)
    }
    for frame in frames {
      dispatchFrame(frame)
    }
    if let oversize {
      fail(RPCLocalError.frameTooLarge(size: oversize.size, limit: oversize.limit))
    }
  }

  func sendData(_ data: Data) {
    delegate?.rpc(self, send: data)
  }

  private func fail(_ error: Error) {
    guard !failed else { return }
    failed = true
    failureError = error
    buffer.removeAll()
    let drainedPending = pending
    pending.removeAll()
    let drainedStreams = pendingResponseStreams
    pendingResponseStreams.removeAll()
    for (_, continuation) in drainedPending {
      continuation.resume(throwing: error)
    }
    for (_, continuation) in drainedStreams {
      continuation.resume(throwing: error)
    }
    delegate?.rpc(self, didFailWith: error)
  }

  func registerOutgoingStream(_ stream: OutgoingStream, forId id: UInt) {
    outgoingStreams[id] = stream
  }

  func removeIncomingStream(forId id: UInt) {
    incomingStreams.removeValue(forKey: id)
  }

  func removeOutgoingStream(forId id: UInt) {
    outgoingStreams.removeValue(forKey: id)
  }

  // Responder receives type=REQUEST with stream=OPEN → create IncomingStream, send ack
  private func handleRequestStreamOpen(_ req: RequestMessage) {
    guard req.id != 0 else { return }  // events (id=0) can't have streams
    let incoming = IncomingStream(requestId: req.id, mask: StreamFlag.request, rpc: self)
    incomingStreams[req.id] = incoming
    // Send OPEN ack: type=STREAM with REQUEST|OPEN
    sendData(Messages.encodeStream(id: req.id, flags: StreamFlag.request | StreamFlag.open))
    // Deliver to onRequest with the stream attached
    let incomingRequest = IncomingRequest(
      id: req.id, command: req.command, data: req.data, rpc: self,
      requestStream: incoming)
    Task { [weak self] in
      guard let self, let delegate = self.delegate else { return }
      try? await delegate.rpc(self, didReceiveRequest: incomingRequest)
    }
  }

  // Initiator receives type=RESPONSE with stream=OPEN → create IncomingStream, resolve pending
  private func handleResponseStreamOpen(_ resp: ResponseMessage) {
    // Fail any normal-response continuation that was expecting Data, not a stream
    if let normalCont = pending.removeValue(forKey: resp.id) {
      normalCont.resume(
        throwing: RPCRemoteError(
          message: "Expected normal response", code: "ERR_UNEXPECTED_STREAM"))
    }
    guard let continuation = pendingResponseStreams.removeValue(forKey: resp.id) else { return }
    let incoming = IncomingStream(requestId: resp.id, mask: StreamFlag.response, rpc: self)
    incomingStreams[resp.id] = incoming
    // Send OPEN ack: type=STREAM with RESPONSE|OPEN
    sendData(Messages.encodeStream(id: resp.id, flags: StreamFlag.response | StreamFlag.open))
    continuation.resume(returning: incoming)
  }

  private func handleStreamMessage(_ msg: StreamMessage) {
    if msg.flags & StreamFlag.open != 0 {
      // OPEN ack from remote — currently no action needed
      return
    }

    if msg.flags & StreamFlag.data != 0 {
      if let incoming = incomingStreams[msg.id] {
        if let data = msg.data {
          incoming.push(data)
        }
      }
      return
    }

    if msg.flags & StreamFlag.end != 0 {
      if let incoming = incomingStreams[msg.id] {
        incoming.end()
      }
      return
    }

    if msg.flags & StreamFlag.close != 0 {
      if msg.flags & StreamFlag.error != 0 {
        if let incoming = incomingStreams.removeValue(forKey: msg.id) {
          incoming.destroy(error: msg.error)
        }
      } else {
        if let incoming = incomingStreams.removeValue(forKey: msg.id) {
          incoming.end()
        }
      }
      return
    }

    if msg.flags & StreamFlag.destroy != 0 {
      if let outgoing = outgoingStreams[msg.id] {
        if msg.flags & StreamFlag.error != 0 {
          outgoing.destroy(error: msg.error)
        } else {
          outgoing.destroy()
        }
      }
      return
    }
  }

  private func dispatchFrame(_ frame: Data) {
    let message: DecodedMessage?
    do {
      message = try Messages.decodeFrame(frame)
    } catch {
      fail(error)
      return
    }

    guard let message else { return }

    switch message {
    case .request(let req):
      if req.stream == StreamFlag.open {
        handleRequestStreamOpen(req)
      } else {
        Task { [weak self] in
          guard let self, let delegate = self.delegate else { return }
          if req.id == 0 {
            let event = IncomingEvent(command: req.command, data: req.data)
            await delegate.rpc(self, didReceiveEvent: event)
          } else {
            let incoming = IncomingRequest(
              id: req.id, command: req.command, data: req.data, rpc: self)
            try? await delegate.rpc(self, didReceiveRequest: incoming)
          }
        }
      }
    case .stream(let s):
      handleStreamMessage(s)
    case .response(let resp):
      if resp.stream == StreamFlag.open {
        handleResponseStreamOpen(resp)
      } else {
        let continuation = pending.removeValue(forKey: resp.id)
        if let continuation {
          switch resp.result {
          case .success(let data):
            continuation.resume(returning: data)
          case .remoteError(let msg, let code, let errno):
            continuation.resume(throwing: RPCRemoteError(message: msg, code: code, errno: errno))
          }
        }
        // If client expected a response stream but got a normal response, fail it
        if let streamCont = pendingResponseStreams.removeValue(forKey: resp.id) {
          streamCont.resume(
            throwing: RPCRemoteError(
              message: "Expected stream response", code: "ERR_NOT_STREAM"))
        }
      }
    }
  }
}
