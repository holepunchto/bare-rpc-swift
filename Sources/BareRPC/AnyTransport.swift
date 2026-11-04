import Foundation

/// A ``Transport`` built from its parts: the sequence of bytes that arrive
/// from the peer, and closures that write to the peer and close the
/// transport.
public struct AnyTransport<Input: AsyncSequence & Sendable>: Transport
where Input.Element == Data {
  public typealias Element = Data

  private let input: Input
  private let writer: @Sendable (Data) async throws -> Void
  private let closer: @Sendable () async -> Void

  /// - Parameters:
  ///   - input: The bytes that arrive from the peer. The transport ends once
  ///     it finishes.
  ///   - write: Writes data to the peer and waits for it to drain.
  ///   - close: Closes the transport. By default, it does nothing.
  public init(
    _ input: Input,
    write: @escaping @Sendable (Data) async throws -> Void,
    close: @escaping @Sendable () async -> Void = {}
  ) {
    self.input = input
    self.writer = write
    self.closer = close
  }

  public func write(_ data: Data) async throws {
    try await writer(data)
  }

  public func close() async {
    await closer()
  }

  public func makeAsyncIterator() -> Input.AsyncIterator {
    input.makeAsyncIterator()
  }
}
