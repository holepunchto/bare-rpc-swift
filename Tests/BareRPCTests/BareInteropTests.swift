import Foundation
import Testing

@testable import BareRPC

/// Live interop against the JS `bare-rpc` reference; covers what byte
/// fixtures can't (timing, ordering, multi-frame handshakes).
@Suite(.timeLimit(.minutes(1))) struct BareInteropTests {

  // Mirrored in rpc_peer.js.
  enum Command {
    static let requestStreamCollector: UInt = 5
    static let responseStreamProducer: UInt = 6
    static let requestStreamCollectorReply: UInt = 21
    static let unknown: UInt = 99
  }

  @Test @MainActor func requestStreamToBare() async throws {
    guard let peer = try BarePeer.spawnIfAvailable() else { return }
    defer { peer.stop() }

    let (events, continuation) = AsyncStream<IncomingEvent>.makeStream()
    peer.delegate.onEvent = { event in
      continuation.yield(event)
    }

    let stream = try peer.rpc.createRequestStream(command: Command.requestStreamCollector)
    await stream.write(Data("foo".utf8))
    await stream.write(Data("bar".utf8))
    await stream.write(Data("baz".utf8))
    stream.end()

    for await event in events where event.command == Command.requestStreamCollectorReply {
      #expect(event.data == Data("foobarbaz".utf8))
      continuation.finish()
    }
  }

  @Test @MainActor func concurrentStreamsBothDirections() async throws {
    guard let peer = try BarePeer.spawnIfAvailable() else { return }
    defer { peer.stop() }

    let (events, continuation) = AsyncStream<IncomingEvent>.makeStream()
    peer.delegate.onEvent = { event in continuation.yield(event) }

    let outgoing = try peer.rpc.createRequestStream(command: Command.requestStreamCollector)
    await outgoing.write(Data("foo".utf8))
    await outgoing.write(Data("bar".utf8))
    await outgoing.write(Data("baz".utf8))
    outgoing.end()

    async let incomingChunks: [Data] = {
      let incoming = try await peer.rpc.requestWithResponseStream(
        command: Command.responseStreamProducer)
      var chunks: [Data] = []
      for try await chunk in incoming { chunks.append(chunk) }
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

    let incoming = try await peer.rpc.requestWithResponseStream(
      command: Command.responseStreamProducer)

    var chunks: [Data] = []
    for try await chunk in incoming {
      chunks.append(chunk)
    }
    #expect(chunks == [Data([0x0A]), Data([0x14, 0x1E]), Data([0x28, 0x32, 0x3C])])
  }

}

// MARK: - Bare peer harness

@MainActor
final class BarePeer {
  let rpc: RPC
  let delegate: BarePeerDelegate
  private let process: Process
  private let stdinPipe: Pipe
  private let stdoutPipe: Pipe
  private let stdoutContinuation: AsyncStream<Data>.Continuation

  private init(process: Process, stdinPipe: Pipe, stdoutPipe: Pipe) {
    self.process = process
    self.stdinPipe = stdinPipe
    self.stdoutPipe = stdoutPipe
    self.delegate = BarePeerDelegate(writeHandle: stdinPipe.fileHandleForWriting)
    let rpc = RPC(delegate: self.delegate)
    self.rpc = rpc
    // Serialize through one MainActor task; spawning a Task per chunk
    // loses FIFO across hops (CI saw bytes arrive as [1, 3, 2]).
    let (byteStream, byteCont) = AsyncStream<Data>.makeStream()
    self.stdoutContinuation = byteCont
    Task { @MainActor in
      for await data in byteStream {
        rpc.receive(data)
      }
    }
  }

  /// Skips locally when prerequisites are missing; fails on CI.
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
    peer.delegate.onError = { error in
      Issue.record("unexpected RPC failure: \(error)")
    }

    let cont = peer.stdoutContinuation
    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty { return }
      cont.yield(data)
    }

    // Drain stderr so the child can't block on a full pipe.
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
    stdoutContinuation.finish()
    try? stdinPipe.fileHandleForWriting.close()
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
    do {
      try writeHandle.write(contentsOf: data)
    } catch {
      onError?(error)
    }
  }

  func rpc(_ rpc: RPC, didReceiveRequest request: IncomingRequest) async throws {
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
