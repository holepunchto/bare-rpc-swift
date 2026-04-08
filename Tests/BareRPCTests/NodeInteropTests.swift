import Foundation
import Testing

@testable import BareRPC

/// Live interop tests that run the JavaScript `bare-rpc` reference as a Node
/// subprocess and exchange streaming frames with it over stdio pipes.
///
/// Scope: only the bidirectional stream OPEN handshake and DATA / END / CLOSE
/// flow. Single-frame request/response/event semantics are already covered
/// byte-for-byte by `InteropFixturesTests`; running them through a live peer
/// would be redundant. The streaming pair is kept because the multi-frame
/// handshake (REQUEST|OPEN ↔ STREAM|OPEN ack) cannot be verified with byte
/// fixtures alone — it depends on both sides agreeing on ordering and timing.
///
/// These tests require:
///   - a `node` binary on PATH
///   - a sibling checkout of holepunchto/bare-rpc at `../bare-rpc` with
///     `node_modules` installed (`npm install`)
///
/// If either prerequisite is missing the tests early-return with a warning
/// rather than failing, so they don't break contributors who haven't set up
/// the sibling checkout.
@Suite struct NodeInteropTests {

  @Test @MainActor func requestStreamToNode() async throws {
    guard let peer = try NodePeer.spawnIfAvailable() else { return }
    defer { peer.stop() }

    // Swift opens a request stream to command 5; the Node peer collects all
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

  @Test @MainActor func responseStreamFromNode() async throws {
    guard let peer = try NodePeer.spawnIfAvailable() else { return }
    defer { peer.stop() }

    // Swift requests a response stream for command 6; the Node peer writes
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

// MARK: - Node peer harness

/// Spawns `node rpc_peer.js` and wires its stdin/stdout to a Swift `RPC`
/// instance. All interaction with `RPC` is serialized on the main actor.
@MainActor
final class NodePeer {
  let rpc: RPC
  let delegate: NodePeerDelegate
  private let process: Process
  private let stdinPipe: Pipe
  private let stdoutPipe: Pipe

  private init(process: Process, stdinPipe: Pipe, stdoutPipe: Pipe) {
    self.process = process
    self.stdinPipe = stdinPipe
    self.stdoutPipe = stdoutPipe
    self.delegate = NodePeerDelegate(writeHandle: stdinPipe.fileHandleForWriting)
    self.rpc = RPC(delegate: delegate)
  }

  /// Returns nil (with a warning) if the environment is missing node or the
  /// sibling bare-rpc checkout.
  static func spawnIfAvailable() throws -> NodePeer? {
    let fm = FileManager.default

    // Locate the script relative to this source file.
    let thisFile = URL(fileURLWithPath: #filePath)
    let fixturesDir = thisFile.deletingLastPathComponent()
      .appendingPathComponent("Fixtures")
    let scriptURL = fixturesDir.appendingPathComponent("rpc_peer.js")

    // Locate sibling bare-rpc checkout: ../../../bare-rpc relative to Tests/BareRPCTests/.
    let repoRoot =
      thisFile
      .deletingLastPathComponent()  // BareRPCTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // bare-rpc-swift
    let siblingBareRPC =
      repoRoot
      .deletingLastPathComponent()
      .appendingPathComponent("bare-rpc")
    let siblingNodeModules = siblingBareRPC.appendingPathComponent("node_modules")

    guard fm.fileExists(atPath: scriptURL.path) else {
      Issue.record("rpc_peer.js not found at \(scriptURL.path)", severity: .warning)
      return nil
    }
    guard fm.fileExists(atPath: siblingBareRPC.path) else {
      Issue.record(
        "skipping node interop: sibling bare-rpc checkout not found at \(siblingBareRPC.path)",
        severity: .warning)
      return nil
    }
    guard fm.fileExists(atPath: siblingNodeModules.path) else {
      Issue.record(
        "skipping node interop: run `npm install` inside \(siblingBareRPC.path) first",
        severity: .warning)
      return nil
    }

    // Find node on PATH.
    guard let nodePath = which("node") else {
      Issue.record("skipping node interop: `node` not found on PATH", severity: .warning)
      return nil
    }

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: nodePath)
    process.arguments = [scriptURL.path, siblingBareRPC.path]
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let peer = NodePeer(process: process, stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)

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

final class NodePeerDelegate: RPCDelegate, @unchecked Sendable {
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
    // Node peer is always the responder in these tests.
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
