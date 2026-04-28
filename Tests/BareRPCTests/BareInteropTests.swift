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
///   - a `bare` binary on PATH (`npm install -g bare`)
///   - `npm install` to have been run in `Tests/BareRPCTests/Fixtures/`
///
/// If either prerequisite is missing the tests early-return with a printed
/// notice locally, but record a hard failure when `CI=true` is set so a
/// misconfigured runner can never silently false-pass.
@Suite struct BareInteropTests {

  @Test @MainActor func requestStreamToBare() async throws {
    guard let peer = try BarePeer.spawnIfAvailable() else { return }
    defer { peer.stop() }

    // Swift opens a request stream to command 5; the Bare peer collects all
    // chunks and replies with an event 21 carrying the concatenation. This
    // exercises the full request-stream OPEN handshake (REQUEST|OPEN →
    // STREAM|REQUEST|OPEN ack) and DATA / END / CLOSE flow across the wire.
    try await confirmation { confirm in
      peer.delegate.onEvent = { event in
        if event.command == 21 {
          #expect(event.data == Data("foobarbaz".utf8))
          confirm()
        }
      }

      let stream = peer.rpc.createRequestStream(command: 5)
      stream.write(Data("foo".utf8))
      stream.write(Data("bar".utf8))
      stream.write(Data("baz".utf8))
      stream.end()

      for _ in 0..<200 {
        try await Task.sleep(nanoseconds: 10_000_000)
      }
    }
  }

  @Test @MainActor func responseStreamFromBare() async throws {
    guard let peer = try BarePeer.spawnIfAvailable() else { return }
    defer { peer.stop() }

    // Swift requests a response stream for command 6; the Bare peer writes
    // three fixed chunks and ends. This exercises the response-stream
    // handshake (REQUEST → RESPONSE|OPEN → STREAM|RESPONSE|OPEN ack) and
    // DATA / END / CLOSE delivery in the JS → Swift direction.
    let incoming = try await peer.rpc.requestWithResponseStream(command: 6)

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
    let nodeModules = fixturesDir.appendingPathComponent("node_modules")

    guard fm.fileExists(atPath: scriptURL.path) else {
      report("rpc_peer.js not found at \(scriptURL.path)")
      return nil
    }
    guard fm.fileExists(atPath: nodeModules.path) else {
      report("run `npm install` in \(fixturesDir.path) first")
      return nil
    }
    guard let barePath = which("bare") else {
      report("`bare` not found on PATH (`npm install -g bare`)")
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
    // Give the peer a moment to exit cleanly on its own.
    let deadline = Date().addingTimeInterval(1.0)
    while process.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning {
      process.terminate()
    }
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
    // FileHandle.write is synchronous; bare-rpc-swift calls send from the
    // caller's context (main actor in these tests).
    do {
      try writeHandle.write(contentsOf: data)
    } catch {
      onError?(error)
    }
  }

  func rpc(_ rpc: RPC, didReceiveRequest request: IncomingRequest) async throws {
    // Bare peer is always the responder in these tests.
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
  let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
  for dir in pathEnv.split(separator: ":") {
    let candidate = "\(dir)/\(binary)"
    if FileManager.default.isExecutableFile(atPath: candidate) {
      return candidate
    }
  }
  return nil
}
