import Foundation

public class IncomingEvent {
  public let command: UInt
  public let data: Data?

  init(command: UInt, data: Data?) {
    self.command = command
    self.data = data
  }
}
