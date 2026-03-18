// Sources/BareRPC/IncomingEvent.swift
import Foundation

/// Handle for an incoming fire-and-forget event (id == 0).
/// Unlike IncomingRequest, events have no reply/reject methods.
public class IncomingEvent {
  public let command: Int
  public let data: Data?

  init(command: Int, data: Data?) {
    self.command = command
    self.data = data
  }
}
