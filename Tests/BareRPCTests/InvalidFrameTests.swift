import Foundation
import Testing

@testable import BareRPC

private final class Peer {
  let delegate = Capture()
  let rpc: RPC
  private let errors = Locked<[Error]>([])
  private let handling = Locked(0)

  init(onRequest: @escaping (IncomingRequest) async throws -> Void = { try await $0.reply(nil) }) {
    rpc = delegate.rpc()
    let errors = errors
    let handling = handling
    delegate.onRequest = { req in
      handling.withLock { $0 += 1 }
      defer { handling.withLock { $0 -= 1 } }
      try await onRequest(req)
    }
    delegate.onError = { errors.append($0) }
  }

  var error: Error? { errors.value.first }
  var errorCount: Int { errors.value.count }
  var sentStreams: [StreamMessage] { delegate.sentStreams }
  var responseIds: [UInt] { delegate.sentResponses.map(\.id) }

  func receive(_ frames: [Data]) async {
    for frame in frames { await rpc.receive(frame) }
  }

  // A handler awaits the frames it sends, so once no handler runs and nothing
  // is tracked, every frame has reached the transport.
  func settle() async throws {
    _ = try await waitUntil {
      guard handling.value == 0 else { return false }
      return await rpc.trackedStateCount == 0
    }
  }
}

private func body(_ bytes: [UInt8]) -> Data {
  makeRawFrame(Data(bytes))
}

private func expectInvalidMessage(_ peer: Peer, sourceLocation: SourceLocation = #_sourceLocation) {
  guard case .invalidMessage = peer.error as? RPCError else {
    Issue.record(
      "Expected invalidMessage, got \(String(describing: peer.error))",
      sourceLocation: sourceLocation)
    return
  }
  #expect(peer.errorCount == 1, sourceLocation: sourceLocation)
}

@Suite struct InvalidFrameTests {

  static let undecodable: [(String, Data)] = [
    ("empty body", body([])),
    ("unknown type without an id", body([99])),
    ("truncated varint", body([1, 0xFE])),
    ("bad varint", body([1, 0xFF, 0x01, 0x02])),
    ("request data past the frame", body([1, 1, 1, 0, 10, 0xAA, 0xBB])),
    (
      "request data length past Int.max",
      body([1, 1, 1, 0, 0xFF] + [UInt8](repeating: 0xFF, count: 8))
    ),
    ("has-error byte other than 0 or 1", body([2, 1, 2, 0, 1, 0xAA])),
    ("error message past the frame", body([2, 1, 1, 0, 5, 0x61])),
    (
      "error code length past Int.max",
      body([2, 1, 1, 0, 0, 0xFF] + [UInt8](repeating: 0xFF, count: 8))
    ),
    ("stream data past the frame", body([3, 1, 0xFD, 0x10, 0x01, 4])),
    ("stream error past the frame", body([3, 1, 0xFD, 0x82, 0x01, 9])),
  ]

  @Test(arguments: undecodable) func undecodableFrameFailsTheConnection(
    _ name: String, _ frame: Data
  ) async throws {
    let peer = Peer()
    await peer.receive([frame])
    expectInvalidMessage(peer)
    #expect(await peer.rpc.trackedStateCount == 0, "\(name)")
  }

  @Test func unknownMessageTypeFailsTheSession() async throws {
    let transport = TestTransport()
    let rpc = RPC(transport)
    await transport.input.feed(body([99, 0]))

    await #expect(throws: RPCError.unknownMessage(type: 99)) { try await rpc.wait() }
  }

  static let violations: [(String, Data)] = [
    ("response with id 0", Messages.encodeResponse(id: 0, data: nil)),
    ("error response with id 0", Messages.encodeErrorResponse(id: 0, message: "x", code: "x")),
    ("response with an unknown stream", Messages.encodeResponse(id: 1, stream: 2, data: nil)),
    ("error response with a stream", body([2, 1, 1, 1, 0, 0, 0])),
    ("stream with id 0", Messages.encodeStream(id: 0, flags: StreamFlag.request | StreamFlag.end)),
    (
      "stream with both directions",
      Messages.encodeStream(
        id: 1, flags: StreamFlag.request | StreamFlag.response | StreamFlag.end)
    ),
    ("stream with no direction", Messages.encodeStream(id: 1, flags: StreamFlag.end)),
    ("stream with no event", Messages.encodeStream(id: 1, flags: StreamFlag.request)),
    (
      "stream with two events",
      Messages.encodeStream(id: 1, flags: StreamFlag.request | StreamFlag.end | StreamFlag.pause)
    ),
    (
      "stream with unknown flags",
      Messages.encodeStream(id: 1, flags: 0x400 | StreamFlag.request | StreamFlag.end)
    ),
    (
      "stream error on a data event",
      Messages.encodeStream(
        id: 1, flags: StreamFlag.request | StreamFlag.data | StreamFlag.error,
        error: RPCRemoteError(message: "x", code: "x"))
    ),
    (
      "request with an unknown stream",
      Messages.encodeRequest(id: 1, command: 1, stream: 2, data: nil)
    ),
    (
      "cancel with id 0",
      Messages.encodeCancel(id: 0, error: RPCRemoteError(message: "x", code: "x"))
    ),
  ]

  @Test(arguments: violations) func protocolViolationFailsTheConnection(
    _ name: String, _ frame: Data
  ) async throws {
    let peer = Peer()
    await peer.receive([frame])
    expectInvalidMessage(peer)
    #expect(await peer.rpc.trackedStateCount == 0, "\(name)")
  }

  @Test func requestWithTheIdOfALiveRequestFailsTheConnection() async throws {
    let peer = Peer(onRequest: { _ in })
    await peer.receive([Messages.encodeRequest(id: 5, command: 1, data: nil)])
    #expect(peer.error == nil)

    await peer.receive([Messages.encodeRequest(id: 5, command: 1, data: nil)])
    expectInvalidMessage(peer)
  }

  @Test func requestWithTheIdOfAnOpenRequestStreamFailsTheConnection() async throws {
    let peer = Peer(onRequest: { req in
      _ = try await req.createRequestStream()
      try await req.reply(nil)
    })
    await peer.receive([
      Messages.encodeRequest(id: 5, command: 1, stream: StreamFlag.open, data: nil)
    ])
    _ = try await waitUntil { peer.responseIds == [5] }
    #expect(peer.error == nil)

    await peer.receive([Messages.encodeRequest(id: 5, command: 1, data: nil)])
    expectInvalidMessage(peer)
    #expect(await peer.rpc.trackedStateCount == 0)
  }

  @Test func requestMayReuseTheIdOfAnAnsweredRequest() async throws {
    let peer = Peer()
    await peer.receive([Messages.encodeRequest(id: 5, command: 1, data: nil)])
    try await peer.settle()

    await peer.receive([Messages.encodeRequest(id: 5, command: 1, data: nil)])
    try await peer.settle()

    #expect(peer.error == nil)
    #expect(peer.responseIds == [5, 5])
    #expect(await peer.rpc.trackedStateCount == 0)
  }

  @Test func staleAndUnknownReferencesAreIgnoredAndKeepNoState() async throws {
    let peer = Peer()
    await peer.receive([Messages.encodeRequest(id: 9, command: 1, data: nil)])
    try await peer.settle()

    var frames = [
      Messages.encodeResponse(id: 9, data: Data([1])),
      Messages.encodeResponse(id: 9, stream: StreamFlag.open, data: nil),
      Messages.encodeErrorResponse(id: 9, message: "x", code: "x"),
    ]
    for direction in [StreamFlag.request, StreamFlag.response] {
      for event in [
        StreamFlag.open, StreamFlag.close, StreamFlag.pause, StreamFlag.resume, StreamFlag.end,
        StreamFlag.destroy,
      ] {
        frames.append(Messages.encodeStream(id: 9, flags: direction | event))
      }
      frames.append(
        Messages.encodeStream(id: 9, flags: direction | StreamFlag.data, data: Data([1])))
      frames.append(
        Messages.encodeStream(
          id: 9, flags: direction | StreamFlag.close | StreamFlag.error,
          error: RPCRemoteError(message: "x", code: "x")))
    }
    await peer.receive(frames)

    #expect(peer.error == nil)
    #expect(await peer.rpc.trackedStateCount == 0)
    #expect(await peer.rpc.earlyResponseOpenCount == 0)

    await peer.receive([Messages.encodeRequest(id: 10, command: 1, data: nil)])
    try await peer.settle()
    #expect(peer.responseIds == [9, 10])
  }

  /// A JS peer opens its side of the response stream before it sends the
  /// request, as in the "request and response stream" test of bare-rpc.
  @Test func responseStreamWorksWhenThePeerOpensItBeforeTheRequest() async throws {
    let peer = Peer(onRequest: { req in
      let reply = try await req.createResponseStream()
      for try await data in try await req.createRequestStream()! {
        #expect(data == Data("foo".utf8))
        try await reply.write(Data("bar".utf8))
        await reply.end()
      }
    })

    let request = StreamFlag.request
    let response = StreamFlag.response
    await peer.receive([
      Messages.encodeStream(id: 1, flags: response | StreamFlag.open),
      Messages.encodeRequest(id: 1, command: 42, stream: StreamFlag.open, data: nil),
    ])
    _ = try await waitUntil {
      peer.sentStreams.contains(where: { $0.flags == request | StreamFlag.open })
    }
    await peer.receive([
      Messages.encodeStream(id: 1, flags: request | StreamFlag.data, data: Data("foo".utf8)),
      Messages.encodeStream(id: 1, flags: request | StreamFlag.end),
    ])
    try await peer.settle()

    #expect(peer.error == nil)
    #expect(await peer.rpc.trackedStateCount == 0)
    #expect(await peer.rpc.earlyResponseOpenCount == 0)
    let replies = peer.sentStreams.filter { $0.flags & response != 0 }
    #expect(
      replies.map(\.flags) == [
        response | StreamFlag.data, response | StreamFlag.end,
      ])
    #expect(replies.first?.data == Data("bar".utf8))
  }

  @Test func framesForFinishedStreamsAreIgnored() async throws {
    let peer = Peer(onRequest: { req in
      let response = try await req.createResponseStream()
      await response.end()
      try await req.createRequestStream()?.destroy()
    })

    let request = StreamFlag.request
    let response = StreamFlag.response
    await peer.receive([
      Messages.encodeRequest(id: 3, command: 1, stream: StreamFlag.open, data: nil),
      Messages.encodeStream(id: 3, flags: response | StreamFlag.open),
    ])
    try await peer.settle()

    await peer.receive([
      Messages.encodeStream(id: 3, flags: request | StreamFlag.data, data: Data([1])),
      Messages.encodeStream(id: 3, flags: request | StreamFlag.end),
      Messages.encodeStream(id: 3, flags: request | StreamFlag.close),
      Messages.encodeStream(
        id: 3, flags: request | StreamFlag.close | StreamFlag.error,
        error: RPCRemoteError(message: "x", code: "x")),
      Messages.encodeStream(id: 3, flags: response | StreamFlag.pause),
      Messages.encodeStream(id: 3, flags: response | StreamFlag.resume),
      Messages.encodeStream(id: 3, flags: response | StreamFlag.destroy),
      Messages.encodeStream(
        id: 3, flags: response | StreamFlag.destroy | StreamFlag.error,
        error: RPCRemoteError(message: "x", code: "x")),
    ])

    #expect(peer.error == nil)
    #expect(await peer.rpc.trackedStateCount == 0)
  }

  /// Feeds seeded random and mutated frames. The connection must either fail
  /// with one clean error or keep answering requests, and must not keep state
  /// for anything that is no longer live.
  @Test func fuzzedFramesFailCleanlyOrKeepWorking() async throws {
    var random = SplitMix64(seed: 0x5EED)
    var failures = 0

    for _ in 0..<2000 {
      let peer = Peer(onRequest: { req in
        try await req.createRequestStream()?.destroy()
        try await req.reply(nil)
      })

      for _ in 0..<8 {
        await peer.rpc.receive(fuzzedFrame(&random))
      }

      if peer.error != nil {
        failures += 1
        #expect(peer.errorCount == 1)
        #expect(await peer.rpc.trackedStateCount == 0)
        continue
      }

      try await peer.settle()
      #expect(await peer.rpc.trackedStateCount == 0)

      let id: UInt = 0xFFFF_FFFF_0000
      await peer.receive([Messages.encodeRequest(id: id, command: 1, data: nil)])
      _ = try await waitUntil(stepNs: 1_000_000) {
        peer.responseIds.contains(id) || peer.error != nil
      }
      #expect(peer.error != nil || peer.responseIds.contains(id))
    }

    #expect(failures > 0)
    #expect(failures < 2000)
  }
}

private struct SplitMix64 {
  var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
}

private func validFrame(_ random: inout SplitMix64) -> Data {
  let id = UInt(random.below(4))
  let direction = random.below(2) == 0 ? StreamFlag.request : StreamFlag.response
  let events = [
    StreamFlag.open, StreamFlag.close, StreamFlag.pause, StreamFlag.resume, StreamFlag.data,
    StreamFlag.end, StreamFlag.destroy,
  ]
  switch random.below(5) {
  case 0: return Messages.encodeRequest(id: id, command: 1, data: Data([1, 2]))
  case 1: return Messages.encodeRequest(id: id + 1, command: 1, stream: StreamFlag.open, data: nil)
  case 2: return Messages.encodeResponse(id: id + 1, data: Data([3]))
  case 3: return Messages.encodeErrorResponse(id: id + 1, message: "x", code: "y", errno: 1)
  default:
    return Messages.encodeStream(
      id: id + 1, flags: direction | events[random.below(events.count)], data: Data([4]))
  }
}

private func fuzzedFrame(_ random: inout SplitMix64) -> Data {
  switch random.below(8) {
  case 0..<6:
    return validFrame(&random)
  case 6:
    var frame = validFrame(&random)
    for _ in 0...random.below(3) {
      let index = 4 + random.below(frame.count - 4)
      frame[index] = UInt8(truncatingIfNeeded: random.next())
    }
    return frame
  default:
    let bytes = (0..<random.below(24)).map { _ in UInt8(truncatingIfNeeded: random.next()) }
    return makeRawFrame(Data(bytes))
  }
}
