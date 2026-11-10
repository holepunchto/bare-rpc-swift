import CompactEncoding
import Foundation

/// One end of a bare-rpc session over a ``Transport``.
///
/// The session reads the bytes of the peer from the transport and writes its
/// own frames to it, one at a time and in order. It ends once the transport
/// finishes, with ``RPCError/channelClosed`` or with
/// ``RPCError/invalidMessage(_:)`` if it ended in the middle of a frame, once
/// the transport throws, with that error, or once ``close()`` is called.
/// Pending requests then throw the error, and open incoming and outgoing
/// streams fail with it. However the session ends, it then closes the
/// transport.
public actor RPC {
  /// A closure that answers a request of the peer. Throwing before the request
  /// has been answered rejects it with the error.
  public typealias RequestHandler = @Sendable (IncomingRequest) async throws -> Void
  /// A closure that receives an event of the peer. Throwing fails the session.
  public typealias EventHandler = @Sendable (IncomingEvent) async throws -> Void

  public static let defaultMaxFrameSize = 16 * 1024 * 1024
  public static let defaultMaxBufferedBytes = 16 * 1024 * 1024

  public let maxFrameSize: Int
  public let maxBufferedBytes: Int

  private var buffer = Data()
  var idCounter: UInt = 1
  // How each request of this side expects its answer.
  private enum Awaiting {
    case reply(CheckedContinuation<Data?, Error>)
    case stream(CheckedContinuation<IncomingStream, Error>)
    case streamedReply(AsyncThrowingStream<Data?, Error>.Continuation)

    func fail(_ error: Error) {
      switch self {
      case .reply(let continuation): continuation.resume(throwing: error)
      case .stream(let continuation): continuation.resume(throwing: error)
      case .streamedReply(let continuation): continuation.finish(throwing: error)
      }
    }
  }

  private var awaiting: [UInt: Awaiting] = [:]
  // A request id is only unique to the side that sent the request, so a
  // stream is told apart by whether it carries a request or a response body.
  private struct StreamKey: Hashable {
    let id: UInt
    let mask: UInt
  }

  private var incomingStreams: [StreamKey: IncomingStream] = [:]
  private var outgoingStreams: [StreamKey: OutgoingStream] = [:]

  private var unansweredPeerRequests: [UInt: IncomingRequest] = [:]
  // The task of each request and event handler that is still running, keyed
  // by the order of its message, as the peer may reuse the id of a request
  // whose handler still runs, and events have no id.
  private var handlerTasks: [Int: Task<Void, Never>] = [:]
  private var nextHandlerTask = 0
  // The latest request of each id whose handler still runs, which a cancel of
  // the peer cancels.
  private var runningRequests: [UInt: (request: IncomingRequest, task: Task<Void, Never>)] = [:]
  private var highestPeerRequestId: UInt = 0
  // Response streams that the peer opened before this side created them,
  // which a JS peer does as soon as it reads a reply as a stream.
  private var earlyResponseOpens: Set<UInt> = []
  private static let maxEarlyResponseOpens = 1024
  private var failureError: Error?

  private var failed: Bool { failureError != nil }

  // Ids are never reused, so a late frame for a finished request can't be
  // mistaken for one of a new request.
  private func nextId() throws -> UInt {
    if let failureError { throw failureError }
    defer { idCounter += 1 }
    return idCounter
  }

  private let handler: any Handler
  private let transport: any Transport
  // Set once the session has failed with an error other than
  // `RPCError.channelClosed`, after which queued frames are not written.
  private var dropsWrites = false
  private let writes: AsyncStream<(Data, CheckedContinuation<Void, Never>?)>.Continuation
  private let reading = ReadingTask()
  private var closeWaiters: [CheckedContinuation<Error, Never>] = []
  private var transportClosed = false
  private var transportCloseWaiters: [CheckedContinuation<Void, Never>] = []

  /// Starts a session over `transport` that passes the requests and events of
  /// the peer to `handler`.
  ///
  /// - Parameters:
  ///   - transport: The transport to the peer. A frame is only written once
  ///     the one before it has been, so a slow transport holds back the
  ///     writers. A write that throws fails the session with the error.
  ///   - handler: Answers the requests and receives the events of the peer.
  ///   - maxFrameSize: The size of the largest frame accepted from the peer,
  ///     including its length prefix.
  ///   - maxBufferedBytes: The most bytes that an incoming stream buffers
  ///     before they are read. A peer that sends more, as it ignored the
  ///     request to pause, fails the session with ``RPCError/streamOverflow``.
  public init(
    _ transport: some Transport,
    handler: some Handler,
    maxFrameSize: Int = RPC.defaultMaxFrameSize,
    maxBufferedBytes: Int = RPC.defaultMaxBufferedBytes
  ) {
    precondition(maxFrameSize > 0, "maxFrameSize must be positive")
    precondition(maxBufferedBytes > 0, "maxBufferedBytes must be positive")
    self.maxFrameSize = maxFrameSize
    self.maxBufferedBytes = maxBufferedBytes
    self.handler = handler
    self.transport = transport

    let (frames, writes) = AsyncStream<(Data, CheckedContinuation<Void, Never>?)>.makeStream()
    self.writes = writes

    Task { [self] in
      for await (frame, written) in frames {
        await self.perform(frame)
        written?.resume()
      }
      await transport.close()
      await self.didCloseTransport()
    }

    reading.start(Task { [self] in await self.read(transport) })
  }

  /// Starts a session over `transport` that passes the requests and events of
  /// the peer to closures.
  ///
  /// - Parameters:
  ///   - transport: The transport to the peer, as for
  ///     ``init(_:handler:maxFrameSize:maxBufferedBytes:)``.
  ///   - maxFrameSize: The size of the largest frame accepted from the peer,
  ///     including its length prefix.
  ///   - maxBufferedBytes: The most bytes that an incoming stream buffers
  ///     before they are read, as for
  ///     ``init(_:handler:maxFrameSize:maxBufferedBytes:)``.
  ///   - onRequest: Answers each request of the peer. Without it, requests are
  ///     rejected with the code `UNKNOWN_COMMAND`.
  ///   - onEvent: Receives each event of the peer. Without it, events are
  ///     dropped.
  public init(
    _ transport: some Transport,
    maxFrameSize: Int = RPC.defaultMaxFrameSize,
    maxBufferedBytes: Int = RPC.defaultMaxBufferedBytes,
    onRequest: RequestHandler? = nil,
    onEvent: EventHandler? = nil
  ) {
    self.init(
      transport, handler: ClosureHandler(onRequest: onRequest, onEvent: onEvent),
      maxFrameSize: maxFrameSize, maxBufferedBytes: maxBufferedBytes)
  }

  /// Ends the session, failing pending requests and open incoming streams
  /// with ``RPCError/channelClosed``, and stops reading from the transport.
  /// Once the frames already sent have been written, it closes the transport
  /// and waits for it to close.
  public func close() async {
    await fail(RPCError.channelClosed)
    if transportClosed { return }
    await withCheckedContinuation { transportCloseWaiters.append($0) }
  }

  private func didCloseTransport() {
    transportClosed = true
    let waiters = transportCloseWaiters
    transportCloseWaiters = []
    for waiter in waiters { waiter.resume() }
  }

  /// Waits for the session to end.
  ///
  /// - Throws: The error that failed the session. Nothing is thrown when the
  ///   transport ended cleanly or ``close()`` was called.
  public func wait() async throws {
    let reason = await closedReason()
    if case .channelClosed? = reason as? RPCError { return }
    throw reason
  }

  func closedReason() async -> Error {
    if let failureError { return failureError }
    return await withCheckedContinuation { closeWaiters.append($0) }
  }

  // The transport is iterated off the actor, as its iterator may not be
  // isolated to it.
  private nonisolated func read(_ transport: some Transport) async {
    do {
      for try await chunk in transport {
        guard await receive(chunk) else { return }
      }
      await fail(
        buffer.isEmpty ? RPCError.channelClosed : RPCError.invalidMessage("Truncated frame"))
    } catch {
      await fail(error)
    }
  }

  private func perform(_ frame: Data) async {
    guard !dropsWrites else { return }
    do {
      try await transport.write(frame)
    } catch {
      await fail(error)
    }
  }

  /// Sends a request for `command` and waits for its reply. Cancelling the
  /// task that waits cancels the request, and the peer is told to stop
  /// handling it.
  ///
  /// - Parameter timeout: The seconds to wait for the reply before the
  ///   request is cancelled and ``RPCError/timeout`` is thrown. It must not be
  ///   negative or NaN. A timeout too long to ever pass, such as `.infinity`,
  ///   waits for the reply as if there were none.
  /// - Throws: The ``RPCRemoteError`` that the peer rejected the request with,
  ///   `CancellationError` if the task was cancelled, ``RPCError/timeout``, or
  ///   the error that ended the session.
  public func request(_ command: UInt, data: Data? = nil, timeout: TimeInterval? = nil)
    async throws -> Data?
  {
    if let timeout { precondition(timeout >= 0, "timeout must not be negative or NaN") }
    try Task.checkCancellation()
    let id = try nextId()
    let frame = Messages.encodeRequest(id: id, command: command, data: data)
    let timer = timeout.flatMap { startTimeout(id, after: $0) }
    defer { timer?.cancel() }
    return try await Self.cancellable(self, id) {
      try await withCheckedThrowingContinuation { continuation in
        awaiting[id] = .reply(continuation)
        queue(frame)
      }
    }
  }

  /// Sends an event for `command`, which gets no reply, and waits for it to be
  /// written. Once the session has ended, the event is dropped.
  public func event(_ command: UInt, data: Data? = nil) async {
    await sendAndWait(Messages.encodeEvent(command: command, data: data))
  }

  /// Sends a request for `command` whose body is streamed, and returns the
  /// stream to write it to. The reply of the peer is not read.
  public func createRequestStream(command: UInt) throws -> OutgoingStream {
    let id = try nextId()
    let stream = OutgoingStream(requestId: id, mask: StreamFlag.request, rpc: self)
    registerOutgoingStream(stream)
    queue(Messages.encodeRequest(id: id, command: command, stream: StreamFlag.open, data: nil))
    return stream
  }

  /// Sends a request for `command` whose body is streamed, and returns the
  /// stream to write it to along with a closure that waits for the reply.
  /// Cancelling the task that waits for the reply cancels the request.
  public func streamRequest(command: UInt) throws
    -> (outgoing: OutgoingStream, response: @Sendable () async throws -> Data?)
  {
    let id = try nextId()
    let outgoing = OutgoingStream(requestId: id, mask: StreamFlag.request, rpc: self)
    registerOutgoingStream(outgoing)

    var continuation: AsyncThrowingStream<Data?, Error>.Continuation!
    let channel = AsyncThrowingStream<Data?, Error> { continuation = $0 }
    awaiting[id] = .streamedReply(continuation)

    queue(Messages.encodeRequest(id: id, command: command, stream: StreamFlag.open, data: nil))

    let received = ReceivedFlag()
    let response: @Sendable () async throws -> Data? = { [weak self] in
      if received.set() {
        throw RPCError.alreadyReceived("Response is already being received")
      }
      return try await Self.cancellable(self, id) {
        for try await value in channel { return value }
        try Task.checkCancellation()
        return nil
      }
    }
    return (outgoing, response)
  }

  /// Sends a request for `command` whose body and reply are both streamed,
  /// and returns both streams once the peer has opened its reply. Cancelling
  /// the task that waits, or the task that reads the reply before it has
  /// ended, cancels the request.
  public func createBidirectionalStream(command: UInt) async throws
    -> (outgoing: OutgoingStream, incoming: IncomingStream)
  {
    try Task.checkCancellation()
    let id = try nextId()
    let outgoing = OutgoingStream(requestId: id, mask: StreamFlag.request, rpc: self)
    registerOutgoingStream(outgoing)
    let incoming = try await Self.cancellable(self, id) {
      try await withCheckedThrowingContinuation { continuation in
        awaiting[id] = .stream(continuation)
        queue(
          Messages.encodeRequest(id: id, command: command, stream: StreamFlag.open, data: nil))
        queue(Messages.encodeStream(id: id, flags: StreamFlag.response | StreamFlag.open))
      }
    }
    return (outgoing, incoming)
  }

  /// Sends a request for `command` and returns the stream of its reply. A
  /// plain reply of the peer is read as a stream of at most one chunk.
  /// Cancelling the task that waits for the stream, or the task that reads it
  /// before it has ended, cancels the request.
  public func requestWithResponseStream(command: UInt, data: Data? = nil) async throws
    -> IncomingStream
  {
    try Task.checkCancellation()
    let id = try nextId()
    let frame = Messages.encodeRequest(id: id, command: command, data: data)
    return try await Self.cancellable(self, id) {
      try await withCheckedThrowingContinuation { continuation in
        awaiting[id] = .stream(continuation)
        queue(frame)
        queue(Messages.encodeStream(id: id, flags: StreamFlag.response | StreamFlag.open))
      }
    }
  }

  private static let cancelled = RPCRemoteError(
    message: "Request was cancelled", code: "CANCELLED")
  private static let timedOut = RPCRemoteError(message: "Request timed out", code: "TIMEOUT")

  private static func cancellable<T>(
    _ rpc: RPC?, _ id: UInt, isolation: isolated (any Actor)? = #isolation,
    _ operation: () async throws -> T
  ) async throws -> T {
    try await withTaskCancellationHandler(
      operation: operation,
      onCancel: { [weak rpc] in
        Task { await rpc?.cancelRequest(id, error: CancellationError(), reason: Self.cancelled) }
      }, isolation: isolation)
  }

  // The longest timeout whose nanoseconds fit in a `UInt64`.
  private static let maxTimeout = TimeInterval(UInt64.max / 1_000_000_000)

  private func startTimeout(_ id: UInt, after timeout: TimeInterval) -> Task<Void, Never>? {
    guard timeout < Self.maxTimeout else { return nil }
    return Task {
      guard (try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))) != nil else {
        return
      }
      await cancelRequest(id, error: RPCError.timeout, reason: Self.timedOut)
    }
  }

  // Only a request that still waits for its answer is cancelled.
  private func cancelRequest(_ id: UInt, error: Error, reason: RPCRemoteError) async {
    guard let answer = awaiting.removeValue(forKey: id) else { return }
    answer.fail(error)
    await abandonRequest(id, error: error, reason: reason)
  }

  // Only a reply stream that has not ended is cancelled.
  func cancelResponseStream(_ stream: IncomingStream) async {
    let key = StreamKey(id: stream.requestId, mask: StreamFlag.response)
    guard incomingStreams[key] === stream else { return }
    incomingStreams.removeValue(forKey: key)
    await abandonRequest(stream.requestId, error: CancellationError(), reason: Self.cancelled)
  }

  // The peer drops its streams of the request once it reads the cancel, so
  // the body of this side is aborted without sending any frame.
  private func abandonRequest(_ id: UInt, error: Error, reason: RPCRemoteError) async {
    queue(Messages.encodeCancel(id: id, error: reason))
    await outgoingStreams.removeValue(forKey: StreamKey(id: id, mask: StreamFlag.request))?.abort(
      error)
  }

  // Returns whether the session is still reading.
  private func receive(_ data: Data) async -> Bool {
    guard !failed else { return false }
    buffer.append(data)
    var frames: [Data] = []
    var oversizeFrame: (size: Int, limit: Int)?
    while buffer.count >= 4 {
      var peekState = State(Data(buffer.prefix(4)))
      let bodyLen = Int(try! Primitive.UInt32().decode(&peekState))
      let frameLen = 4 + bodyLen
      if frameLen > maxFrameSize {
        oversizeFrame = (frameLen, maxFrameSize)
        break
      }
      guard buffer.count >= frameLen else { break }
      frames.append(Data(buffer.prefix(frameLen)))
      buffer.removeFirst(frameLen)
    }
    for frame in frames {
      await dispatchFrame(frame)
    }
    if let oversizeFrame {
      await fail(RPCError.frameTooLarge(size: oversizeFrame.size, limit: oversizeFrame.limit))
    }
    return !failed
  }

  // Queues a frame without waiting for it to be written, so that a transport
  // that only drains as the peer reads can't stall the reading here. It
  // doesn't hop onto the actor, so that frames queued by another actor go out
  // in the order that actor queued them. A hop from two tasks can reach the
  // actor in either order, which would let a PAUSE and a RESUME swap. Once the
  // session has ended, the frame is dropped.
  nonisolated func queue(_ data: Data) {
    writes.yield((data, nil))
  }

  func send(_ data: Data, waiting: Bool) async {
    if waiting { await sendAndWait(data) } else { queue(data) }
  }

  func sendAndWait(_ data: Data) async {
    guard !failed else { return }
    await withCheckedContinuation { writes.yield((data, $0)) }
  }

  private func fail(_ error: Error) async {
    guard !failed else { return }
    failureError = error
    if case .channelClosed? = error as? RPCError {} else { dropsWrites = true }
    writes.finish()
    buffer.removeAll()
    let drainedAwaiting = awaiting.values
    awaiting.removeAll()
    let drainedIncoming = incomingStreams.values
    incomingStreams.removeAll()
    let drainedOutgoing = outgoingStreams.values
    outgoingStreams.removeAll()
    unansweredPeerRequests.removeAll()
    earlyResponseOpens.removeAll()
    runningRequests.removeAll()
    let drainedHandlers = handlerTasks.values
    handlerTasks.removeAll()
    for answer in drainedAwaiting {
      answer.fail(error)
    }
    for stream in drainedIncoming {
      await stream.abort(error)
    }
    for stream in drainedOutgoing {
      await stream.abort(error)
    }
    // The streams fail first, so that a handler that reads one sees the error
    // rather than its cancellation.
    for task in drainedHandlers {
      task.cancel()
    }
    reading.cancel()
    let waiters = closeWaiters
    closeWaiters = []
    for waiter in waiters { waiter.resume(returning: error) }
  }

  func registerOutgoingStream(_ stream: OutgoingStream) {
    outgoingStreams[StreamKey(id: stream.requestId, mask: stream.mask)] = stream
  }

  func removeIncomingStream(_ stream: IncomingStream) {
    incomingStreams.removeValue(forKey: StreamKey(id: stream.requestId, mask: stream.mask))
  }

  func removeOutgoingStream(_ stream: OutgoingStream) {
    outgoingStreams.removeValue(forKey: StreamKey(id: stream.requestId, mask: stream.mask))
    if stream.mask == StreamFlag.response {
      answerPeerRequest(stream.requestId)
    }
  }

  /// Returns whether the peer had already opened the response stream.
  @discardableResult
  private func answerPeerRequest(_ id: UInt) -> Bool {
    unansweredPeerRequests.removeValue(forKey: id)
    return earlyResponseOpens.remove(id) != nil
  }

  // A request that the peer has cancelled is no longer unanswered, so its
  // answer is dropped, even once the peer has reused its id.
  private func isUnanswered(_ request: IncomingRequest) -> Bool {
    unansweredPeerRequests[request.id] === request
  }

  func answer(_ request: IncomingRequest, _ frame: Data) async {
    guard isUnanswered(request) else { return }
    answerPeerRequest(request.id)
    await sendAndWait(frame)
  }

  func registerResponseStream(_ stream: OutgoingStream, _ frame: Data, for request: IncomingRequest)
    async
  {
    if let failureError {
      await stream.abort(failureError)
      return
    }
    guard isUnanswered(request) else {
      await stream.drop()
      return
    }
    registerOutgoingStream(stream)
    if answerPeerRequest(stream.requestId) {
      await stream.acknowledge()
      // The peer may have cancelled the request while this waited.
      guard outgoingStreams[StreamKey(id: stream.requestId, mask: stream.mask)] === stream else {
        return
      }
    }
    await sendAndWait(frame)
  }

  func openRequestStream(_ stream: IncomingStream, for request: IncomingRequest) async {
    if let error = failureError ?? request.cancellationError {
      await stream.abort(error)
      return
    }
    // A request whose id the peer has reused no longer owns its body.
    let key = StreamKey(id: stream.requestId, mask: StreamFlag.request)
    if (currentRequest(request.id) ?? request) !== request || incomingStreams[key] != nil {
      await stream.abort(RPCError.channelClosed)
      return
    }
    incomingStreams[key] = stream
    queue(
      Messages.encodeStream(id: stream.requestId, flags: StreamFlag.request | StreamFlag.open))
  }

  // A request from the peer stays live until it has been answered and its
  // request stream, if any, has finished. Only then may the peer reuse its id.
  private func isLivePeerRequest(_ id: UInt) -> Bool {
    unansweredPeerRequests[id] != nil
      || incomingStreams[StreamKey(id: id, mask: StreamFlag.request)] != nil
      || outgoingStreams[StreamKey(id: id, mask: StreamFlag.response)] != nil
  }

  var trackedStateCount: Int {
    awaiting.count + incomingStreams.count + outgoingStreams.count + unansweredPeerRequests.count
  }

  var earlyResponseOpenCount: Int { earlyResponseOpens.count }

  var handlerTaskCount: Int { handlerTasks.count }

  @discardableResult
  private func startHandler(_ deliver: @escaping @Sendable (isolated RPC) async -> Void)
    -> Task<Void, Never>
  {
    let key = nextHandlerTask
    nextHandlerTask += 1
    let task = Task {
      await deliver(self)
      handlerTasks.removeValue(forKey: key)
    }
    handlerTasks[key] = task
    return task
  }

  private func deliver(_ request: IncomingRequest) async {
    defer {
      if runningRequests[request.id]?.request === request {
        runningRequests.removeValue(forKey: request.id)
      }
    }
    do {
      try await handler.handle(request)
    } catch {
      await request.fail(error)
    }
  }

  private func deliver(_ event: IncomingEvent) async {
    do {
      try await handler.handle(event)
    } catch {
      await fail(error)
    }
  }

  private func handleResponseStreamOpen(_ resp: ResponseMessage) async {
    switch awaiting[resp.id] {
    case .reply, .streamedReply:
      awaiting.removeValue(forKey: resp.id)?.fail(RPCError.unexpectedStream)
      queue(Messages.encodeStream(id: resp.id, flags: StreamFlag.response | StreamFlag.destroy))
      await outgoingStreams[StreamKey(id: resp.id, mask: StreamFlag.request)]?.release(
        error: RPCRemoteError(
          message: "Request was answered with a stream", code: "UNEXPECTED_STREAM"))
    case .stream(let continuation):
      awaiting[resp.id] = nil
      let incoming = IncomingStream(requestId: resp.id, mask: StreamFlag.response, rpc: self)
      incomingStreams[StreamKey(id: resp.id, mask: StreamFlag.response)] = incoming
      continuation.resume(returning: incoming)
    case nil:
      return
    }
  }

  // A request whose handler still runs is cancelled even once it has been
  // answered, as the handler may still open its body or reply stream.
  private func handleCancel(_ msg: CancelMessage) async {
    let task = runningRequests[msg.id]?.task
    currentRequest(msg.id)?.cancel(msg.error)
    answerPeerRequest(msg.id)
    await incomingStreams.removeValue(forKey: StreamKey(id: msg.id, mask: StreamFlag.request))?
      .abort(msg.error)
    await outgoingStreams.removeValue(forKey: StreamKey(id: msg.id, mask: StreamFlag.response))?
      .drop()
    // The body fails first, so that a handler that reads it sees the error of
    // the peer rather than its cancellation.
    task?.cancel()
  }

  // The latest request of an id whose handler still runs or that has not been
  // answered.
  private func currentRequest(_ id: UInt) -> IncomingRequest? {
    runningRequests[id]?.request ?? unansweredPeerRequests[id]
  }

  private func handleStreamMessage(_ msg: StreamMessage) async {
    let key = StreamKey(id: msg.id, mask: msg.flags & (StreamFlag.request | StreamFlag.response))

    if msg.flags & StreamFlag.open != 0 {
      await handleStreamOpen(msg, key)
      return
    }

    if msg.flags & StreamFlag.close != 0 {
      if msg.flags & StreamFlag.error != 0 {
        await incomingStreams[key]?.destroy(error: msg.error, waiting: false)
      } else {
        await incomingStreams[key]?.end()
      }
      return
    }

    if msg.flags & StreamFlag.pause != 0 {
      await outgoingStreams[key]?.cork()
      return
    }

    if msg.flags & StreamFlag.resume != 0 {
      await outgoingStreams[key]?.uncork()
      return
    }

    if msg.flags & StreamFlag.data != 0 {
      if let incoming = incomingStreams[key], let data = msg.data,
        await incoming.push(data) > maxBufferedBytes
      {
        await fail(RPCError.streamOverflow)
      }
      return
    }

    if msg.flags & StreamFlag.end != 0 {
      if let incoming = incomingStreams[key] {
        await incoming.end()
      }
      return
    }

    if msg.flags & StreamFlag.destroy != 0 {
      if key.mask == StreamFlag.response { earlyResponseOpens.remove(msg.id) }
      await outgoingStreams[key]?.destroy(error: msg.error, waiting: false)
      return
    }
  }

  private func handleStreamOpen(_ msg: StreamMessage, _ key: StreamKey) async {
    if let outgoing = outgoingStreams[key] {
      await outgoing.acknowledge()
      return
    }
    guard key.mask == StreamFlag.response, !earlyResponseOpens.contains(msg.id) else { return }
    // Any other open is for a request that has already been answered.
    if unansweredPeerRequests[msg.id] == nil && msg.id <= highestPeerRequestId { return }
    if earlyResponseOpens.count >= Self.maxEarlyResponseOpens {
      await fail(RPCError.invalidMessage("Too many response streams opened early"))
      return
    }
    earlyResponseOpens.insert(msg.id)
  }

  // Frames that a valid peer can never send. Frames that a valid peer can send
  // because of a race, such as those for an id that has finished, are not
  // violations and are ignored instead.
  private func violation(of message: DecodedMessage) -> String? {
    switch message {
    case .request(let req):
      if req.id == 0 && req.stream != 0 { return "Event with a stream" }
      if req.stream != 0 && req.stream != StreamFlag.open { return "Invalid request stream" }
      if req.id != 0 && isLivePeerRequest(req.id) { return "Duplicate request id" }
    case .response(let resp):
      if resp.id == 0 { return "Response with id 0" }
      if resp.stream != 0 && resp.stream != StreamFlag.open { return "Invalid response stream" }
      if case .remoteError = resp.result, resp.stream != 0 { return "Error response with a stream" }
    case .stream(let msg):
      if msg.id == 0 { return "Stream message with id 0" }
      if !Self.validStreamFlags.contains(msg.flags) { return "Invalid stream flags" }
    case .cancel(let msg):
      if msg.id == 0 { return "Cancel with id 0" }
    }
    return nil
  }

  // One direction and one event, with an error only on CLOSE or DESTROY.
  private static let validStreamFlags: Set<UInt> = {
    let events = [
      StreamFlag.open, StreamFlag.close, StreamFlag.pause, StreamFlag.resume, StreamFlag.data,
      StreamFlag.end, StreamFlag.destroy, StreamFlag.close | StreamFlag.error,
      StreamFlag.destroy | StreamFlag.error,
    ]
    return Set(
      [StreamFlag.request, StreamFlag.response].flatMap { direction in
        events.map { direction | $0 }
      })
  }()

  private func dispatchFrame(_ frame: Data) async {
    guard !failed else { return }
    let message: DecodedMessage?
    do {
      message = try Messages.decodeFrame(frame)
    } catch let error as RPCError {
      await fail(error)
      return
    } catch {
      await fail(RPCError.invalidMessage("Malformed frame"))
      return
    }

    guard let message else { return }

    if let violation = violation(of: message) {
      await fail(RPCError.invalidMessage(violation))
      return
    }

    switch message {
    case .request(let req) where req.id == 0:
      startHandler { await $0.deliver(IncomingEvent(command: req.command, data: req.data)) }
    case .request(let req):
      highestPeerRequestId = max(highestPeerRequestId, req.id)
      // The request stream is only opened, and the OPEN acked, once the
      // handler reads it. Until then its frames are dropped, as in JS.
      let body =
        req.stream == StreamFlag.open
        ? IncomingStream(requestId: req.id, mask: StreamFlag.request, rpc: self) : nil
      let request = IncomingRequest(
        id: req.id, command: req.command, data: req.data, rpc: self, requestStream: body)
      unansweredPeerRequests[req.id] = request
      runningRequests[req.id] = (request, startHandler { await $0.deliver(request) })
    case .cancel(let msg):
      await handleCancel(msg)
    case .stream(let s):
      await handleStreamMessage(s)
    case .response(let resp) where resp.stream == StreamFlag.open:
      await handleResponseStreamOpen(resp)
    case .response(let resp):
      switch awaiting.removeValue(forKey: resp.id) {
      case .reply(let continuation):
        switch resp.result {
        case .success(let data): continuation.resume(returning: data)
        case .remoteError(let error): continuation.resume(throwing: error)
        }
      case .streamedReply(let continuation):
        let error: RPCRemoteError?
        switch resp.result {
        case .success(let data):
          error = nil
          continuation.yield(data)
          continuation.finish()
        case .remoteError(let remoteError):
          error = remoteError
          continuation.finish(throwing: remoteError)
        }
        await outgoingStreams[StreamKey(id: resp.id, mask: StreamFlag.request)]?.release(
          error: error)
      // A plain reply to a request whose reply is read as a stream is
      // delivered as a stream of at most one chunk.
      case .stream(let continuation):
        switch resp.result {
        case .success(let data):
          let incoming = IncomingStream(requestId: resp.id, mask: StreamFlag.response, rpc: self)
          if let data, !data.isEmpty { await incoming.push(data) }
          await incoming.end()
          continuation.resume(returning: incoming)
        case .remoteError(let error):
          continuation.resume(throwing: error)
        }
      case nil:
        return
      }
    }
  }
}

private struct ClosureHandler: Handler {
  let onRequest: RPC.RequestHandler?
  let onEvent: RPC.EventHandler?

  func handle(_ request: IncomingRequest) async throws {
    guard let onRequest else { return try await request.rejectUnknownCommand() }
    try await onRequest(request)
  }

  func handle(_ event: IncomingEvent) async throws {
    try await onEvent?(event)
  }
}

private final class ReceivedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  /// Sets the flag and returns whether it was already set.
  func set() -> Bool {
    lock.withLock {
      defer { value = true }
      return value
    }
  }
}

// Holds the task that reads the transport, so that the nonisolated init can
// start it and a later failure can cancel it.
private final class ReadingTask: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<Void, Never>?
  private var cancelled = false

  func start(_ task: Task<Void, Never>) {
    let cancelled = lock.withLock {
      self.task = task
      return self.cancelled
    }
    if cancelled { task.cancel() }
  }

  func cancel() {
    let task = lock.withLock {
      cancelled = true
      defer { self.task = nil }
      return self.task
    }
    task?.cancel()
  }
}
