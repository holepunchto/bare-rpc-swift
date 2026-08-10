import Foundation
import Testing

@testable import BareRPC

/// Conformance against holepunchto/hrpc-test's shared wire vectors - the same
/// bytes the JS, C and Python implementations are held to.
///
/// The fixtures are read from the installed npm package rather than copied into
/// this repo, so they cannot drift from upstream the way a vendored set would.
@Suite struct WireVectorsTests {

  static let families = ["envelope", "error", "boundary", "dispatch"]

  @Test(arguments: families) func decodes(_ family: String) throws {
    let (frames, messages) = try Vectors.family(family)
    #expect(frames.count == messages.count, "one frame per message")

    for (frame, message) in zip(frames, messages) {
      let note = message["note"] as? String ?? family
      let descriptor = message["descriptor"] as! [String: Any]

      guard let decoded = try Messages.decodeFrame(Vectors.data(hex: frame)) else {
        Issue.record("\(note): decoded to nil")
        continue
      }

      switch decoded {
      case .request(let request):
        #expect(descriptor["type"] as? Int == 1, "\(note): is a request")
        #expect(request.id == UInt(descriptor["id"] as! Int), "\(note): id")
        #expect(request.command == UInt(descriptor["command"] as! Int), "\(note): command")
        #expect(request.stream == UInt(descriptor["stream"] as! Int), "\(note): stream")
        Vectors.expectPayload(request.data, descriptor, note)

      case .response(let response):
        #expect(descriptor["type"] as? Int == 2, "\(note): is a response")
        #expect(response.id == UInt(descriptor["id"] as! Int), "\(note): id")
        #expect(response.stream == UInt(descriptor["stream"] as! Int), "\(note): stream")

        switch response.result {
        case .success(let data):
          Vectors.expectPayload(data, descriptor, note)
        case .remoteError(let message, let code, let errno):
          let expected = descriptor["error"] as! [String: Any]
          #expect(message == expected["message"] as? String, "\(note): error message")
          #expect(code == expected["code"] as? String, "\(note): error code")
          #expect(errno == expected["errno"] as? Int, "\(note): error errno")
        }

      case .stream(let stream):
        #expect(descriptor["type"] as? Int == 3, "\(note): is a stream frame")
        #expect(stream.id == UInt(descriptor["id"] as! Int), "\(note): id")
        #expect(stream.flags == UInt(descriptor["stream"] as! Int), "\(note): flags")

        if let expected = descriptor["error"] as? [String: Any] {
          #expect(stream.error?.message == expected["message"] as? String, "\(note): error")
        } else {
          Vectors.expectPayload(stream.data, descriptor, note)
        }
      }
    }
  }

  @Test(arguments: families) func encodes(_ family: String) throws {
    let (frames, messages) = try Vectors.family(family)

    for (frame, message) in zip(frames, messages) {
      let note = message["note"] as? String ?? family
      let descriptor = message["descriptor"] as! [String: Any]
      let id = UInt(descriptor["id"] as! Int)
      let payload = (descriptor["data"] as? String).map { Vectors.data(hex: $0) }

      let encoded: Data
      switch descriptor["type"] as! Int {
      case 1:
        encoded = Messages.encodeRequest(
          id: id, command: UInt(descriptor["command"] as! Int),
          stream: UInt(descriptor["stream"] as! Int), data: payload)
      case 2:
        if let error = descriptor["error"] as? [String: Any] {
          encoded = Messages.encodeErrorResponse(
            id: id, message: error["message"] as! String, code: error["code"] as! String,
            errno: error["errno"] as! Int)
        } else {
          encoded = Messages.encodeResponse(
            id: id, stream: UInt(descriptor["stream"] as! Int), data: payload)
        }
      default:
        let error = (descriptor["error"] as? [String: Any]).map {
          RPCRemoteError(
            message: $0["message"] as! String, code: $0["code"] as! String,
            errno: $0["errno"] as! Int)
        }
        encoded = Messages.encodeStream(
          id: id, flags: UInt(descriptor["stream"] as! Int), data: payload, error: error)
      }

      #expect(Vectors.hex(encoded) == frame, "\(note)")
    }
  }

  /// Both classes of rejected frame - malformed, and well-formed with an
  /// unrecognized type - must be signalled, not skipped. See Rejecting frames in
  /// hrpc-test's WIRE.md.
  @Test func rejectsNegativeFrames() throws {
    for entry in try Vectors.negative() {
      let reason = entry["reason"] as! String
      let frame = Vectors.data(hex: entry["hex"] as! String)

      #expect(throws: (any Error).self, "\(reason)") {
        try Messages.decodeFrame(frame)
      }
    }
  }

  @Test func resplitsAConcatenatedStream() throws {
    let sequence = try Vectors.sequence()
    var remaining = Vectors.data(hex: sequence["concatenated"] as! String)
    var seen = 0

    while remaining.count >= 4 {
      // Every frame is a uint32 little-endian body length followed by the body
      let body = remaining.prefix(4).reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
      let total = 4 + Int(body)

      #expect(try Messages.decodeFrame(remaining.prefix(total)) != nil, "frame \(seen)")

      remaining = remaining.dropFirst(total)
      seen += 1
    }

    #expect(seen == sequence["count"] as! Int, "all frames re-split")
  }
}

/// Loads the vectors from the installed hrpc-test package.
enum Vectors {
  static let directory: URL = {
    // Tests/BareRPCTests/WireVectorsTests.swift -> repo root
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()

    // npm hoists workspace dependencies to the root, but not always
    for candidate in ["node_modules", "Tests/BareRPCTests/Fixtures/node_modules"] {
      let path = root.appendingPathComponent("\(candidate)/hrpc-test/fixtures")
      if FileManager.default.fileExists(atPath: path.path) { return path }
    }

    fatalError("hrpc-test is not installed - run npm install")
  }()

  static func family(_ name: String) throws -> ([String], [[String: Any]]) {
    (
      try json("\(name)/frames.json") as! [String],
      try json("\(name)/messages.json") as! [[String: Any]]
    )
  }

  static func negative() throws -> [[String: Any]] {
    try json("negative/frames.json") as! [[String: Any]]
  }

  static func sequence() throws -> [String: Any] {
    try json("sequence/frames.json") as! [String: Any]
  }

  static func json(_ relative: String) throws -> Any {
    try JSONSerialization.jsonObject(
      with: Data(contentsOf: directory.appendingPathComponent(relative)))
  }

  static func data(hex: String) -> Data {
    var out = Data(capacity: hex.count / 2)
    var index = hex.startIndex

    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      out.append(UInt8(hex[index..<next], radix: 16)!)
      index = next
    }

    return out
  }

  /// Exact comparison: a payload-bearing frame decodes to a buffer even when it
  /// is zero length, and a frame with no dataLen on the wire decodes to nil.
  static func expectPayload(_ data: Data?, _ descriptor: [String: Any], _ note: String) {
    #expect(hex(data) == descriptor["data"] as? String, "\(note): data")
  }

  static func hex(_ data: Data?) -> String? {
    data.map { $0.map { String(format: "%02x", $0) }.joined() }
  }
}
