// Sources/BareRPC/Messages.swift
import Foundation
import CompactEncoding

// MARK: - Decoded message types

public enum DecodedMessage {
  case request(RequestMessage)
  case response(ResponseMessage)
}

public struct RequestMessage {
  public let id: UInt
  public let command: UInt
  public let data: Data?
}

public struct ResponseMessage {
  public let id: UInt
  public let result: ResponseResult
}

public enum ResponseResult {
  case success(Data?)
  case remoteError(message: String, code: String, errno: Int)
}

// MARK: - Messages

public enum Messages {

  // MARK: Encode

  public static func encodeRequest(id: UInt, command: UInt, data: Data?) -> Data {
    var state = State()
    preencodeRequestBody(&state, id: id, command: command, data: data)
    state.allocate()
    encodeRequestBody(&state, id: id, command: command, data: data)
    return prependLength(state.buffer)
  }

  public static func encodeEvent(command: UInt, data: Data?) -> Data {
    return encodeRequest(id: 0, command: command, data: data)
  }

  public static func encodeResponse(id: UInt, data: Data?) -> Data {
    var state = State()
    Primitive.UInt().preencode(&state, 2)         // type = 2
    Primitive.UInt().preencode(&state, id)
    Primitive.Bool().preencode(&state, false)      // error = false
    Primitive.UInt().preencode(&state, 0)          // stream = 0
    let payload = data ?? Data()
    preencodeBuffer(&state, payload)
    state.allocate()
    try! Primitive.UInt().encode(&state, 2)
    try! Primitive.UInt().encode(&state, id)
    try! Primitive.Bool().encode(&state, false)
    try! Primitive.UInt().encode(&state, 0)
    encodeBuffer(&state, payload)
    return prependLength(state.buffer)
  }

  public static func encodeErrorResponse(id: UInt, message: String, code: String, errno: Int = 0) -> Data {
    var state = State()
    Primitive.UInt().preencode(&state, 2)
    Primitive.UInt().preencode(&state, id)
    Primitive.Bool().preencode(&state, true)       // error = true
    Primitive.UInt().preencode(&state, 0)          // stream = 0
    Primitive.UTF8().preencode(&state, message)
    Primitive.UTF8().preencode(&state, code)
    Primitive.Int().preencode(&state, errno)
    state.allocate()
    try! Primitive.UInt().encode(&state, 2)
    try! Primitive.UInt().encode(&state, id)
    try! Primitive.Bool().encode(&state, true)
    try! Primitive.UInt().encode(&state, 0)
    try! Primitive.UTF8().encode(&state, message)
    try! Primitive.UTF8().encode(&state, code)
    try! Primitive.Int().encode(&state, errno)
    return prependLength(state.buffer)
  }

  // MARK: Decode

  /// Decode a full frame (including the 4-byte length prefix).
  /// Returns nil for messages that cannot be handled (streaming, unknown type).
  public static func decodeFrame(_ frame: Data) throws -> DecodedMessage? {
    var state = State(frame)
    // Re-consume and discard the 4-byte frame length prefix
    _ = try Primitive.UInt32().decode(&state)
    // Read message type
    let type_ = try Primitive.UInt().decode(&state)
    switch type_ {
    case 1: return try decodeRequest(&state).map { .request($0) }
    case 2: return try decodeResponse(&state).map { .response($0) }
    default: return nil  // unknown message type — silently discard
    }
  }

  // MARK: Private helpers

  private static func preencodeRequestBody(_ state: inout State, id: UInt, command: UInt, data: Data?) {
    Primitive.UInt().preencode(&state, 1)          // type = 1
    Primitive.UInt().preencode(&state, id)
    Primitive.UInt().preencode(&state, command)
    Primitive.UInt().preencode(&state, 0)          // stream = 0
    preencodeBuffer(&state, data ?? Data())
  }

  private static func encodeRequestBody(_ state: inout State, id: UInt, command: UInt, data: Data?) {
    try! Primitive.UInt().encode(&state, 1)
    try! Primitive.UInt().encode(&state, id)
    try! Primitive.UInt().encode(&state, command)
    try! Primitive.UInt().encode(&state, 0)
    encodeBuffer(&state, data ?? Data())
  }

  /// Preencode a Data value as compact-uint length + raw bytes.
  private static func preencodeBuffer(_ state: inout State, _ data: Data) {
    Primitive.UInt().preencode(&state, Swift.UInt(data.count))
    state.end += data.count
  }

  /// Encode a Data value as compact-uint length + raw bytes.
  private static func encodeBuffer(_ state: inout State, _ data: Data) {
    try! Primitive.UInt().encode(&state, Swift.UInt(data.count))
    if !data.isEmpty {
      state.buffer.replaceSubrange(state.start..<state.start + data.count, with: data)
      state.start += data.count
    }
  }

  /// Decode a compact-uint length-prefixed Data value.
  private static func decodeBuffer(_ state: inout State) throws -> Data {
    let count = Swift.Int(try Primitive.UInt().decode(&state))
    guard state.remaining >= count else { throw MessagesError.outOfBounds }
    let data = state.buffer.subdata(in: state.start..<state.start + count)
    state.start += count
    return data
  }

  private static func prependLength(_ body: Data) -> Data {
    let length = UInt32(body.count)
    var frame = Data(count: 4 + body.count)
    frame[0] = UInt8(length & 0xFF)
    frame[1] = UInt8((length >> 8) & 0xFF)
    frame[2] = UInt8((length >> 16) & 0xFF)
    frame[3] = UInt8((length >> 24) & 0xFF)
    frame.replaceSubrange(4..., with: body)
    return frame
  }

  private static func decodeRequest(_ state: inout State) throws -> RequestMessage? {
    let id      = try Primitive.UInt().decode(&state)
    let command = try Primitive.UInt().decode(&state)
    let stream  = try Primitive.UInt().decode(&state)
    // Streaming requests have no data field — silently discard (not supported in v1)
    guard stream == 0 else { return nil }
    let raw = try decodeBuffer(&state)
    return RequestMessage(id: id, command: command, data: raw.isEmpty ? nil : raw)
  }

  private static func decodeResponse(_ state: inout State) throws -> ResponseMessage? {
    let id     = try Primitive.UInt().decode(&state)
    let isErr  = try Primitive.Bool().decode(&state)
    let stream = try Primitive.UInt().decode(&state)
    // Streaming responses — silently discard (not supported in v1)
    if stream != 0 { return nil }
    if isErr {
      let message = try Primitive.UTF8().decode(&state)
      let code    = try Primitive.UTF8().decode(&state)
      let errno_  = try Primitive.Int().decode(&state)
      return ResponseMessage(id: id, result: .remoteError(message: message, code: code, errno: errno_))
    }
    let raw = try decodeBuffer(&state)
    return ResponseMessage(id: id, result: .success(raw.isEmpty ? nil : raw))
  }
}

// MARK: - Internal errors (protocol-level, not peer-originated)
enum MessagesError: Error {
  case outOfBounds
}
