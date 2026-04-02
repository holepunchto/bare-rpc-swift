import Foundation

public class IncomingRequest {
  public let command: UInt
  public let id: UInt
  public let data: Data?

  private weak var rpc: RPC?

  init(id: UInt, command: UInt, data: Data?, rpc: RPC) {
    self.id = id
    self.command = command
    self.data = data
    self.rpc = rpc
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
}
