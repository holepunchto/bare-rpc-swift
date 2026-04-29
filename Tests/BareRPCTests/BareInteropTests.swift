import Foundation
import Testing

@testable import BareRPC

/// Live interop tests that run the JavaScript `bare-rpc` reference under the
/// Bare runtime as a subprocess and exchange streaming frames with it over
/// stdio pipes.
///
/// Scope: only the bidirectional stream OPEN handshake and DATA / END / CLOSE
/// flow. Single-frame request/response/event semantics are already covered
/// byte-for-byte by `InteropFixturesTests`; running them through a live peer
/// would be redundant. The streaming pair is kept because the multi-frame
/// handshake (REQUEST|OPEN ↔ STREAM|OPEN ack) cannot be verified with byte
/// fixtures alone — it depends on both sides agreeing on ordering and timing.
///
/// These tests require:
///   - a `bare` binary on PATH (`npm install -g bare-runtime`)
///   - `npm install` to have been run at the repo root
///
/// If either prerequisite is missing the tests early-return with a printed
/// notice locally, but record a hard failure when `CI=true` is set so a
/// misconfigured runner can never silently false-pass.
///
/// The suite-wide `.timeLimit` keeps a stuck peer from hanging CI for hours.
@Suite(.timeLimit(.minutes(1))) struct BareInteropTests {

  // Commands the Bare peer handles. Mirrored in rpc_peer.js.
  enum Command {
    static let requestStreamCollector: UInt = 5
    static let responseStreamProducer: UInt = 6
    static let requestStreamCollectorReply: UInt = 21
    static let unknown: UInt = 99
  }

  @Test @MainActor func requestStreamToBare() async throws {
    guard let peer = try BarePeer.spawnIfAvailable() else { return }
    defer { peer.stop() }

    // Swift opens a request stream to command 5; the Bare peer collects all
    // chunks and replies with an event 21 carrying the concatenation. This
    // exercises the full request-stream OPEN handshake (REQUEST|OPEN →
    // STREAM|REQUEST|OPEN ack) and DATA / END / CLOSE flow across the wire.
    let (events, continuation) = AsyncStream<IncomingEvent>.makeStream()
    peer.delegate.onEvent = { event in
      continuation.yield(event)
    }

    let stream = peer.rpc.createRequestStream(command: Command.requestStreamCollector)
    stream.write(Data("foo".utf8))
    stream.write(Data("bar".utf8))
    stream.write(Data("baz".utf8))
    stream.end()

    for await event in events where event.command == Command.requestStreamCollectorReply {
      #expect(event.data == Data("foobarbaz".utf8))
      continuation.finish()
    }
  }

  @Test @MainActor func concurrentStreamsBothDirections() async throws {
    guard let peer = try BarePeer.spawnIfAvailable() else { return }
    defer { peer.stop() }

    // Open a request stream (cmd 5) and a response stream (cmd 6) at the same
    // time. Each has its own request id; verifies Swift correctly multiplexes
    // inbound stream frames by id rather than assuming one stream at a time.
    let (events, continuation) = AsyncStream<IncomingEvent>.makeStream()
    peer.delegate.onEvent = { event in continuation.yield(event) }

    let outgoing = peer.rpc.createRequestStream(command: Command.requestStreamCollector)
    outgoing.write(Data("foo".utf8))
    outgoing.write(Data("bar".utf8))
    outgoing.write(Data("baz".utf8))
    outgoing.end()

    async let incomingChunks: [Data] = {
      let incoming = try await peer.rpc.requestWithResponseStream(
        command: Command.responseStreamProducer)
      var chunks: [Data] = []
      for try await chunk in incoming.stream { chunks.append(chunk) }
      return chunks
    }()

    for await event in events where event.command == Command.requestStreamCollectorReply {
      #expect(event.data == Data("foobarbaz".utf8))
      continuation.finish()
    }

    let chunks = try await incomingChunks
    #expect(chunks == [Data([0x0A]), Data([0x14, 0x1E]), Data([0x28, 0x32, 0x3C])])
  }

  @Test @MainActor func unknownCommandRejectsWithPeerError() async throws {
    guard let peer = try BarePeer.spawnIfAvailable() else { return }
    defer { peer.stop() }

    // Swift sends a regular request for an unknown command. The Bare peer's
    // default handler throws an Error with code='EUNKNOWN' and errno=-1; the
    // JS reference encodes that as a typed error response. Verifies that
    // Swift surfaces the JS-side error fields through `RPCRemoteError`
    // unchanged across the wire.
    do {
      _ = try await peer.rpc.request(Command.unknown)
      Issue.record("expected request to be rejected by peer")
    } catch let error as RPCRemoteError {
      #expect(error.message == "unknown command 99")
      #expect(error.code == "EUNKNOWN")
      #expect(error.errno == -1)
    }
  }

  @Test @MainActor func responseStreamFromBare() async throws {
    guard let peer = try BarePeer.spawnIfAvailable() else { return }
    defer { peer.stop() }

    // Swift requests a response stream for command 6; the Bare peer writes
    // three fixed chunks and ends. This exercises the response-stream
    // handshake (REQUEST → RESPONSE|OPEN → STREAM|RESPONSE|OPEN ack) and
    // DATA / END / CLOSE delivery in the JS → Swift direction.
    let incoming = try await peer.rpc.requestWithResponseStream(
      command: Command.responseStreamProducer)

    var chunks: [Data] = []
    for try await chunk in incoming.stream {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([0x0A]), Data([0x14, 0x1E]), Data([0x28, 0x32, 0x3C])])
  }

}

// MARK: - Bare peer harness

/// Spawns `bare rpc_peer.js` and wires its stdin/stdout to a Swift `RPC`
/// instance. All interaction with `RPC` is serialized on the main actor.
@MainActor
final class BarePeer {
  let rpc: RPC
  let delegate: BarePeerDelegate
  private let process: Process
  private let stdinPipe: Pipe
  private let stdoutPipe: Pipe

  private init(process: Process, stdinPipe: Pipe, stdoutPipe: Pipe) {
    self.process = process
    self.stdinPipe = stdinPipe
    self.stdoutPipe = stdoutPipe
    self.delegate = BarePeerDelegate(writeHandle: stdinPipe.fileHandleForWriting)
    self.rpc = RPC(delegate: delegate)
  }

  /// Returns nil when prerequisites are missing. On CI (`CI=true`) a missing
  /// prerequisite is recorded as a test issue so we don't silently no-op.
  static func spawnIfAvailable() throws -> BarePeer? {
    let fm = FileManager.default
    let isCI = ProcessInfo.processInfo.environment["CI"] == "true"

    func report(_ message: String) {
      if isCI {
        Issue.record(Comment(rawValue: "bare interop unavailable on CI: \(message)"))
      } else {
        print("skipping bare interop: \(message)")
      }
    }

    let thisFile = URL(fileURLWithPath: #filePath)
    let fixturesDir = thisFile.deletingLastPathComponent()
      .appendingPathComponent("Fixtures")
    let scriptURL = fixturesDir.appendingPathComponent("rpc_peer.js")
    let repoRoot =
      thisFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let nodeModules = repoRoot.appendingPathComponent("node_modules")

    guard fm.fileExists(atPath: scriptURL.path) else {
      report("rpc_peer.js not found at \(scriptURL.path)")
      return nil
    }
    guard fm.fileExists(atPath: nodeModules.path) else {
      report("run `npm install` at \(repoRoot.path) first")
      return nil
    }
    guard let barePath = which("bare") else {
      report("`bare` not found on PATH (`npm install -g bare-runtime`)")
      return nil
    }

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: barePath)
    process.arguments = [scriptURL.path]
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let peer = BarePeer(process: process, stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)

    // Read from the peer on a background thread, but hop onto MainActor to
    // call into RPC so all state mutation is serialized.
    stdoutPipe.fileHandleForReading.readabilityHandler = { [weak peer] handle in
      let data = handle.availableData
      if data.isEmpty { return }
      Task { @MainActor [weak peer] in
        peer?.rpc.receive(data)
      }
    }

    // Drain stderr to avoid blocking the child on a full pipe, and surface
    // any peer crash output as a warning.
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty { return }
      if let text = String(data: data, encoding: .utf8) {
        FileHandle.standardError.write(
          Data("[rpc_peer stderr] \(text)".utf8))
      }
    }

    try process.run()
    return peer
  }

  func stop() {
    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    try? stdinPipe.fileHandleForWriting.close()
    // rpc_peer.js exits on stdin EOF, so waitUntilExit returns promptly. If
    // the peer ever hangs, the suite-wide `.timeLimit` fails the test
    // before this call can wedge CI.
    process.waitUntilExit()
  }
}

final class BarePeerDelegate: RPCDelegate, @unchecked Sendable {
  var onEvent: (@MainActor (IncomingEvent) -> Void)?
  var onError: ((Error) -> Void)?

  private let writeHandle: FileHandle

  init(writeHandle: FileHandle) {
    self.writeHandle = writeHandle
  }

  func rpc(_ rpc: RPC, send data: Data) {
    // Writes are serialized by the MainActor hop in spawnIfAvailable's
    // readability handler, so concurrent calls into FileHandle.write don't
    // overlap.
    do {
      try writeHandle.write(contentsOf: data)
    } catch {
      onError?(error)
    }
  }

  func rpc(_ rpc: RPC, didReceiveRequest request: IncomingRequest) async throws {
    // Bare peer is always the responder; an inbound request would be a
    // regression — surface it instead of silently dropping it.
    Issue.record("unexpected request from peer: command=\(request.command)")
  }

  func rpc(_ rpc: RPC, didReceiveEvent event: IncomingEvent) async {
    await MainActor.run {
      onEvent?(event)
    }
  }

  func rpc(_ rpc: RPC, didFailWith error: Error) {
    onError?(error)
  }
}

// MARK: - Helpers

private func which(_ binary: String) -> String? {
  guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else { return nil }
  for dir in pathEnv.split(separator: ":") {
    let candidate = "\(dir)/\(binary)"
    if FileManager.default.isExecutableFile(atPath: candidate) {
      return candidate
    }
  }
  return nil
}
