// Sources/BareRPC/Messages.swift
import Foundation
import CompactEncoding

// MARK: - Decoded message types

public enum DecodedMessage {
  case request(RequestMessage)
  case response(ResponseMessage)
}

public struct RequestMessage {
  public let id: Int
  public let command: Int
  public let data: Data?
}

public struct ResponseMessage {
  public let id: Int
  public let result: ResponseResult
}

public enum ResponseResult {
  case success(Data?)
  case remoteError(message: String, code: String, errno: Int)
  case streamingNotSupported
}

// MARK: - Messages

public enum Messages {

  // MARK: Encode

  public static func encodeRequest(id: Int, command: Int, data: Data?) -> Data {
    var state = State()
    preencodeRequestBody(&state, id: id, command: command, data: data)
    state.allocate()
    encodeRequestBody(&state, id: id, command: command, data: data)
    return prependLength(state.buffer)
  }

  public static func encodeEvent(command: Int, data: Data?) -> Data {
    return encodeRequest(id: 0, command: command, data: data)
  }

  public static func encodeResponse(id: Int, data: Data?) -> Data {
    var state = State()
    Primitive.UInt().preencode(&state, 2)         // type = 2
    Primitive.UInt().preencode(&state, Swift.UInt(id))
    Primitive.Bool().preencode(&state, false)      // error = false
    Primitive.UInt().preencode(&state, 0)          // stream = 0
    let payload = data ?? Data()
    preencodeBuffer(&state, payload)
    state.allocate()
    try! Primitive.UInt().encode(&state, 2)
    try! Primitive.UInt().encode(&state, Swift.UInt(id))
    try! Primitive.Bool().encode(&state, false)
    try! Primitive.UInt().encode(&state, 0)
    encodeBuffer(&state, payload)
    return prependLength(state.buffer)
  }

  public static func encodeErrorResponse(id: Int, message: String, code: String, errno: Int = 0) -> Data {
    var state = State()
    Primitive.UInt().preencode(&state, 2)
    Primitive.UInt().preencode(&state, Swift.UInt(id))
    Primitive.Bool().preencode(&state, true)       // error = true
    Primitive.UInt().preencode(&state, 0)          // stream = 0
    Primitive.UTF8().preencode(&state, message)
    Primitive.UTF8().preencode(&state, code)
    Primitive.Int().preencode(&state, errno)
    state.allocate()
    try! Primitive.UInt().encode(&state, 2)
    try! Primitive.UInt().encode(&state, Swift.UInt(id))
    try! Primitive.Bool().encode(&state, true)
    try! Primitive.UInt().encode(&state, 0)
    try! Primitive.UTF8().encode(&state, message)
    try! Primitive.UTF8().encode(&state, code)
    try! Primitive.Int().encode(&state, errno)
    return prependLength(state.buffer)
  }

  // MARK: Decode

  /// Decode a full frame (including the 4-byte length prefix).
  public static func decodeFrame(_ frame: Data) throws -> DecodedMessage {
    var state = State(frame)
    // Re-consume and discard the 4-byte frame length prefix
    _ = try Primitive.UInt32().decode(&state)
    // Read message type
    let type_ = Swift.Int(try Primitive.UInt().decode(&state))
    switch type_ {
    case 1: return try .request(decodeRequest(&state))
    case 2: return try .response(decodeResponse(&state))
    default: throw MessagesError.unknownMessageType(type_)
    }
  }

  // MARK: Private helpers

  private static func preencodeRequestBody(_ state: inout State, id: Int, command: Int, data: Data?) {
    Primitive.UInt().preencode(&state, 1)          // type = 1
    Primitive.UInt().preencode(&state, Swift.UInt(id))
    Primitive.UInt().preencode(&state, Swift.UInt(command))
    Primitive.UInt().preencode(&state, 0)          // stream = 0
    preencodeBuffer(&state, data ?? Data())
  }

  private static func encodeRequestBody(_ state: inout State, id: Int, command: Int, data: Data?) {
    try! Primitive.UInt().encode(&state, 1)
    try! Primitive.UInt().encode(&state, Swift.UInt(id))
    try! Primitive.UInt().encode(&state, Swift.UInt(command))
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

  private static func decodeRequest(_ state: inout State) throws -> RequestMessage {
    let id      = Swift.Int(try Primitive.UInt().decode(&state))
    let command = Swift.Int(try Primitive.UInt().decode(&state))
    let stream  = Swift.Int(try Primitive.UInt().decode(&state))
    guard stream == 0 else { throw MessagesError.streamingRequest(id: id, command: command) }
    let raw = try decodeBuffer(&state)
    return RequestMessage(id: id, command: command, data: raw.isEmpty ? nil : raw)
  }

  private static func decodeResponse(_ state: inout State) throws -> ResponseMessage {
    let id     = Swift.Int(try Primitive.UInt().decode(&state))
    let isErr  = try Primitive.Bool().decode(&state)
    let stream = Swift.Int(try Primitive.UInt().decode(&state))
    if stream != 0 {
      return ResponseMessage(id: id, result: .streamingNotSupported)
    }
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
  case unknownMessageType(Int)
  // Peer sent a streaming request (stream != 0 in type=1).
  // Carries the request id so the caller can send a rejection response.
  // id == 0 means a streaming event — nothing to reject.
  case streamingRequest(id: Int, command: Int)
  case outOfBounds
}
