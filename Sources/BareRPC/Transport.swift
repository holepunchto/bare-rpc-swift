import Foundation

/// A byte transport that an ``RPC`` runs a session over, such as an `IPC` from
/// bare-stow-host-swift or an `IPC` from bare-kit-swift.
///
/// Iterating it yields the bytes that arrive from the peer, and finishes once
/// the transport has ended.
public protocol Transport: AsyncSequence, Sendable where Element == Data {
  /// Writes `data` to the peer and waits for it to drain.
  func write(_ data: Data) async throws
  /// Closes the transport.
  func close() async
}
