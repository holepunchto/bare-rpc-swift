import Foundation

public class IncomingRequest {
  public let command: UInt
  public let id: UInt
  public let data: Data?
  public let requestStream: IncomingStream?

  private weak var rpc: RPC?

  init(id: UInt, command: UInt, data: Data?, rpc: RPC, requestStream: IncomingStream? = nil) {
    self.id = id
    self.command = command
    self.data = data
    self.rpc = rpc
    self.requestStream = requestStream
  }

  public func reply(_ data: Data? = nil) {
    guard let rpc else { return }
    rpc.sendData(Messages.encodeResponse(id: id, data: data))
  }

  public func reject(_ message: String, code: String = "ERROR", errno: Int = 0) {
    guard let rpc else { return }
    rpc.sendData(
      Messages.encodeErrorResponse(id: id, message: message, code: code, errno: errno))
  }

  public func createResponseStream() -> OutgoingStream? {
    guard let rpc else { return nil }
    let stream = OutgoingStream(requestId: id, mask: StreamFlag.response, rpc: rpc)
    rpc.registerOutgoingStream(stream, forId: id)
    // Send OPEN: type=RESPONSE with stream=OPEN
    rpc.sendData(Messages.encodeResponse(id: id, stream: StreamFlag.open, data: nil))
    return stream
  }
}
