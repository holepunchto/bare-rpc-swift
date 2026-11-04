import Foundation

@testable import BareRPC

/// The bytes a test feeds to an ``RPC`` as if its peer had sent them. A chunk
/// counts as received once the session asks for the next one, so a test can
/// check the state of the session right after feeding it.
final class TestInput: AsyncSequence, @unchecked Sendable {
  typealias Element = Data

  private let lock = NSLock()
  private var queue: [(Result<Data?, Error>, CheckedContinuation<Void, Never>?)] = []
  private var handedOut: [CheckedContinuation<Void, Never>] = []
  private var reader: CheckedContinuation<Data?, Error>?
  private var closed = false

  func feed(_ data: Data) async {
    await push(.success(data))
  }

  func finish(throwing error: Error? = nil) async {
    await push(error.map { .failure($0) } ?? .success(nil))
  }

  func markClosed() {
    let (waiters, reader) = lock.withLock {
      closed = true
      let waiters = handedOut + queue.compactMap(\.1)
      handedOut = []
      queue = []
      defer { self.reader = nil }
      return (waiters, self.reader)
    }
    for waiter in waiters { waiter.resume() }
    reader?.resume(returning: nil)
  }

  private func push(_ item: Result<Data?, Error>) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      let (reader, wasClosed): (CheckedContinuation<Data?, Error>?, Bool) = lock.withLock {
        if closed { return (nil, true) }
        if let reader = self.reader {
          self.reader = nil
          handedOut.append(done)
          return (reader, false)
        }
        queue.append((item, done))
        return (nil, false)
      }
      if let reader {
        reader.resume(with: item)
      } else if wasClosed {
        done.resume()
      }
    }
  }

  fileprivate func next() async throws -> Data? {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (reader: CheckedContinuation<Data?, Error>) in
        let (processed, item): ([CheckedContinuation<Void, Never>], Result<Data?, Error>?) =
          lock.withLock {
            let processed = handedOut
            handedOut = []
            if closed { return (processed, .success(nil)) }
            if !queue.isEmpty {
              let (item, done) = queue.removeFirst()
              if let done { handedOut.append(done) }
              return (processed, item)
            }
            self.reader = reader
            return (processed, nil)
          }
        for waiter in processed { waiter.resume() }
        if let item { reader.resume(with: item) }
      }
    } onCancel: {
      let reader = lock.withLock {
        defer { self.reader = nil }
        return self.reader
      }
      reader?.resume(returning: nil)
    }
  }

  struct AsyncIterator: AsyncIteratorProtocol {
    let input: TestInput

    func next() async throws -> Data? {
      try await input.next()
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(input: self)
  }
}

/// A ``Transport`` that reads from a ``TestInput`` and passes each frame that
/// the session writes to `onWrite`. Closing it runs `onClose` and then closes
/// the input.
final class TestTransport: Transport, @unchecked Sendable {
  typealias Element = Data

  let input: TestInput
  private let onWrite: @Sendable (Data) async throws -> Void
  private let lock = NSLock()
  private var closed = false
  private var closeHandler: (@Sendable () async -> Void)?

  init(
    _ input: TestInput = TestInput(),
    onWrite: @escaping @Sendable (Data) async throws -> Void = { _ in }
  ) {
    self.input = input
    self.onWrite = onWrite
  }

  var isClosed: Bool { lock.withLock { closed } }

  var onClose: (@Sendable () async -> Void)? {
    get { lock.withLock { closeHandler } }
    set { lock.withLock { closeHandler = newValue } }
  }

  func write(_ data: Data) async throws {
    try await onWrite(data)
  }

  func close() async {
    await onClose?()
    lock.withLock { closed = true }
    input.markClosed()
  }

  func makeAsyncIterator() -> TestInput.AsyncIterator {
    input.makeAsyncIterator()
  }
}

/// Runs an ``RPC`` over a ``TestTransport``, recording the frames it writes
/// and passing requests and events to closures that a test can set at any
/// time.
final class Capture: @unchecked Sendable {
  var onSend: ((Data) -> Void)?
  var onRequest: ((IncomingRequest) async throws -> Void)?
  var onEvent: ((IncomingEvent) async throws -> Void)?
  var onError: ((Error) -> Void)?

  let input = TestInput()
  var forward: TestInput?
  private let sent = Locked<[Data]>([])

  private(set) lazy var transport = TestTransport(input) { [weak self] data in
    self?.sent.append(data)
    self?.onSend?(data)
    await self?.forward?.feed(data)
  }

  func rpc(
    maxFrameSize: Int = RPC.defaultMaxFrameSize,
    maxBufferedBytes: Int = RPC.defaultMaxBufferedBytes
  ) -> RPC {
    let rpc = RPC(
      transport,
      maxFrameSize: maxFrameSize,
      maxBufferedBytes: maxBufferedBytes,
      onRequest: { [weak self] in try await self?.onRequest?($0) },
      onEvent: { [weak self] in try await self?.onEvent?($0) }
    )
    return track(rpc)
  }

  var sentFrames: [Data] { sent.value }

  var sentMessages: [DecodedMessage] {
    sentFrames.compactMap { try? Messages.decodeFrame($0) }
  }

  var sentRequests: [RequestMessage] {
    sentMessages.compactMap {
      guard case .request(let req) = $0 else { return nil }
      return req
    }
  }

  var sentResponses: [ResponseMessage] {
    sentMessages.compactMap {
      guard case .response(let resp) = $0 else { return nil }
      return resp
    }
  }

  var sentStreams: [StreamMessage] {
    sentMessages.compactMap {
      guard case .stream(let msg) = $0 else { return nil }
      return msg
    }
  }

  func rpc(handler: some Handler) -> RPC {
    track(RPC(transport, handler: handler))
  }

  func rpcWithoutHandlers() -> RPC {
    track(RPC(transport))
  }

  // The error is reported before the input closes, so a test that has fed the
  // session a frame that fails it can check the error right away.
  private func track(_ rpc: RPC) -> RPC {
    TestInputs.register(input, for: rpc)
    transport.onClose = { [weak self, weak rpc] in
      guard let rpc else { return }
      self?.onError?(await rpc.closedReason())
    }
    return rpc
  }
}

final class RPCPair {
  let client: RPC
  let server: RPC
  let clientSide = Capture()
  let serverSide = Capture()

  convenience init(serverHandler: some Handler) {
    self.init(server: { $0.rpc(handler: serverHandler) })
  }

  init(
    client makeClient: (Capture) -> RPC = { $0.rpc() },
    server makeServer: (Capture) -> RPC = { $0.rpc() }
  ) {
    clientSide.forward = serverSide.input
    serverSide.forward = clientSide.input
    client = makeClient(clientSide)
    server = makeServer(serverSide)
  }
}

enum TestInputs {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var inputs: [ObjectIdentifier: TestInput] = [:]

  static func register(_ input: TestInput, for rpc: RPC) {
    lock.withLock { inputs[ObjectIdentifier(rpc)] = input }
  }

  static func input(for rpc: RPC) -> TestInput? {
    lock.withLock { inputs[ObjectIdentifier(rpc)] }
  }
}

extension RPC {
  /// Feeds `data` to the session as if its peer had sent it, and waits for the
  /// session to have handled it.
  func receive(_ data: Data) async {
    await TestInputs.input(for: self)?.feed(data)
  }
}

/// A value guarded by a lock, for state that a test shares with handlers.
final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value

  init(_ value: Value) {
    stored = value
  }

  var value: Value {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }

  func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
    try lock.withLock { try body(&stored) }
  }
}

extension Locked {
  func append<Element>(_ element: Element) where Value == [Element] {
    withLock { $0.append(element) }
  }
}

/// Polls `condition` until it holds or `timeoutNs` has passed, and returns
/// whether it held.
func waitUntil(
  timeoutNs: UInt64 = 1_000_000_000,
  stepNs: UInt64 = 5_000_000,
  _ condition: () async -> Bool
) async throws -> Bool {
  var elapsed: UInt64 = 0
  while elapsed < timeoutNs {
    if await condition() { return true }
    try await Task.sleep(nanoseconds: stepNs)
    elapsed += stepNs
  }
  return await condition()
}
