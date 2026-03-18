// Sources/BareRPC/IncomingEvent.swift
import Foundation

/// Handle for an incoming fire-and-forget event (id == 0).
///
/// Events are one-way messages with no response mechanism. Unlike ``IncomingRequest``,
/// this type intentionally has no reply or reject methods — matching the JS `IncomingEvent`.
public class IncomingEvent {
  /// The application-defined command identifier.
  public let command: UInt
  /// The event payload, or nil if the sender provided no data.
  public let data: Data?

  init(command: UInt, data: Data?) {
    self.command = command
    self.data = data
  }
}
