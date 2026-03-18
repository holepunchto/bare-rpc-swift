import CompactEncoding
// Sources/BareRPC/Messages.swift
import Foundation

// MARK: - Decoded message types

/// A decoded wire message — either a request or a response.
public enum DecodedMessage {
  case request(RequestMessage)
  case response(ResponseMessage)
}

/// A decoded request message (type == 1).
///
/// Used for both tracked requests (id > 0) and fire-and-forget events (id == 0).
public struct RequestMessage {
  /// Request ID. 0 for events, positive for tracked requests expecting a response.
  public let id: UInt
  /// Application-defined command identifier.
  public let command: UInt
  /// Optional payload bytes. Nil when the sender provided no data.
  public let data: Data?
}

/// A decoded response message (type == 2).
public struct ResponseMessage {
  /// The request ID this response corresponds to.
  public let id: UInt
  /// The response outcome — either success with optional data, or an error.
  public let result: ResponseResult
}

/// The outcome of a response message.
public enum ResponseResult {
  /// Successful response with optional payload data.
  case success(Data?)
  /// Error response from the remote peer, preserving all wire fields.
  case remoteError(message: String, code: String, errno: Int)
}

// MARK: - Codecs

/// Codec for request message bodies (type == 1).
///
/// Wire format: id, command, stream (must be 0), data (length-prefixed buffer).
/// Does not include the type byte — that is handled by ``DecodedMessageCodec``.
public struct RequestMessageCodec: Codec {
  public typealias Value = RequestMessage

  public init() {}

  public func preencode(_ state: inout State, _ value: RequestMessage) {
    Primitive.UInt().preencode(&state, value.id)
    Primitive.UInt().preencode(&state, value.command)
    Primitive.UInt().preencode(&state, 0)
    Primitive.Buffer().preencode(&state, value.data ?? Data())
  }

  public func encode(_ state: inout State, _ value: RequestMessage) throws {
    try Primitive.UInt().encode(&state, value.id)
    try Primitive.UInt().encode(&state, value.command)
    try Primitive.UInt().encode(&state, 0 as UInt)
    try Primitive.Buffer().encode(&state, value.data ?? Data())
  }

  public func decode(_ state: inout State) throws -> RequestMessage {
    let id = try Primitive.UInt().decode(&state)
    let command = try Primitive.UInt().decode(&state)
    let stream = try Primitive.UInt().decode(&state)
    guard stream == 0 else { throw MessagesError.streamingNotSupported }
    let raw = try Primitive.Buffer().decode(&state)
    return RequestMessage(id: id, command: command, data: raw.isEmpty ? nil : raw)
  }
}

/// Codec for response message bodies (type == 2).
///
/// Wire format: id, error flag, stream (must be 0), then either
/// data (length-prefixed buffer) or (message, code, errno).
/// Does not include the type byte — that is handled by ``DecodedMessageCodec``.
public struct ResponseMessageCodec: Codec {
  public typealias Value = ResponseMessage

  public init() {}

  public func preencode(_ state: inout State, _ value: ResponseMessage) {
    Primitive.UInt().preencode(&state, value.id)
    switch value.result {
    case .success(let data):
      Primitive.Bool().preencode(&state, false)
      Primitive.UInt().preencode(&state, 0)
      Primitive.Buffer().preencode(&state, data ?? Data())
    case .remoteError(let message, let code, let errno):
      Primitive.Bool().preencode(&state, true)
      Primitive.UInt().preencode(&state, 0)
      Primitive.UTF8().preencode(&state, message)
      Primitive.UTF8().preencode(&state, code)
      Primitive.Int().preencode(&state, errno)
    }
  }

  public func encode(_ state: inout State, _ value: ResponseMessage) throws {
    try Primitive.UInt().encode(&state, value.id)
    switch value.result {
    case .success(let data):
      try Primitive.Bool().encode(&state, false)
      try Primitive.UInt().encode(&state, 0 as UInt)
      try Primitive.Buffer().encode(&state, data ?? Data())
    case .remoteError(let message, let code, let errno):
      try Primitive.Bool().encode(&state, true)
      try Primitive.UInt().encode(&state, 0 as UInt)
      try Primitive.UTF8().encode(&state, message)
      try Primitive.UTF8().encode(&state, code)
      try Primitive.Int().encode(&state, errno)
    }
  }

  public func decode(_ state: inout State) throws -> ResponseMessage {
    let id = try Primitive.UInt().decode(&state)
    let isErr = try Primitive.Bool().decode(&state)
    let stream = try Primitive.UInt().decode(&state)
    guard stream == 0 else { throw MessagesError.streamingNotSupported }
    if isErr {
      let message = try Primitive.UTF8().decode(&state)
      let code = try Primitive.UTF8().decode(&state)
      let errnoValue = try Primitive.Int().decode(&state)
      return ResponseMessage(
        id: id, result: .remoteError(message: message, code: code, errno: errnoValue))
    }
    let raw = try Primitive.Buffer().decode(&state)
    return ResponseMessage(id: id, result: .success(raw.isEmpty ? nil : raw))
  }
}

/// Codec for decoded messages with type-byte dispatch.
///
/// Wire format: type (1=request, 2=response), then the body encoded by
/// ``RequestMessageCodec`` or ``ResponseMessageCodec``.
public struct DecodedMessageCodec: Codec {
  public typealias Value = DecodedMessage

  public init() {}

  public func preencode(_ state: inout State, _ value: DecodedMessage) {
    switch value {
    case .request(let req):
      Primitive.UInt().preencode(&state, 1)
      RequestMessageCodec().preencode(&state, req)
    case .response(let resp):
      Primitive.UInt().preencode(&state, 2)
      ResponseMessageCodec().preencode(&state, resp)
    }
  }

  public func encode(_ state: inout State, _ value: DecodedMessage) throws {
    switch value {
    case .request(let req):
      try Primitive.UInt().encode(&state, 1 as UInt)
      try RequestMessageCodec().encode(&state, req)
    case .response(let resp):
      try Primitive.UInt().encode(&state, 2 as UInt)
      try ResponseMessageCodec().encode(&state, resp)
    }
  }

  public func decode(_ state: inout State) throws -> DecodedMessage {
    let messageType = try Primitive.UInt().decode(&state)
    switch messageType {
    case 1: return .request(try RequestMessageCodec().decode(&state))
    case 2: return .response(try ResponseMessageCodec().decode(&state))
    default: throw MessagesError.unknownMessageType
    }
  }
}

/// Codec for complete framed messages (4-byte LE length prefix + body).
///
/// Returns nil on decode for streaming messages (stream != 0) and unknown
/// message types, matching the v1 behavior of silently discarding them.
public struct FrameCodec: Codec {
  public typealias Value = DecodedMessage?

  public init() {}

  public func preencode(_ state: inout State, _ value: DecodedMessage?) {
    guard let value else { return }
    Primitive.UInt32().preencode(&state, 0)
    DecodedMessageCodec().preencode(&state, value)
  }

  public func encode(_ state: inout State, _ value: DecodedMessage?) throws {
    guard let value else { return }
    var bodyState = State()
    DecodedMessageCodec().preencode(&bodyState, value)
    try Primitive.UInt32().encode(&state, UInt32(bodyState.end))
    try DecodedMessageCodec().encode(&state, value)
  }

  public func decode(_ state: inout State) throws -> DecodedMessage? {
    _ = try Primitive.UInt32().decode(&state)
    do {
      return try DecodedMessageCodec().decode(&state)
    } catch MessagesError.streamingNotSupported {
      return nil
    } catch MessagesError.unknownMessageType {
      return nil
    }
  }
}

// MARK: - Messages

/// Convenience methods for encoding/decoding bare-rpc wire messages.
///
/// These wrap the codec types (``FrameCodec``, ``DecodedMessageCodec``,
/// ``RequestMessageCodec``, ``ResponseMessageCodec``) with a simpler API
/// used internally by ``RPC`` and ``IncomingRequest``.
public enum Messages {

  // MARK: Encode

  /// Encode a request message (type == 1) with the given ID and command.
  public static func encodeRequest(id: UInt, command: UInt, data: Data?) -> Data {
    let msg = DecodedMessage.request(RequestMessage(id: id, command: command, data: data))
    var state = State()
    FrameCodec().preencode(&state, msg)
    state.allocate()
    try! FrameCodec().encode(&state, msg)
    return state.buffer
  }

  /// Encode a fire-and-forget event (request with id == 0).
  public static func encodeEvent(command: UInt, data: Data?) -> Data {
    return encodeRequest(id: 0, command: command, data: data)
  }

  /// Encode a success response (type == 2, error == false).
  public static func encodeResponse(id: UInt, data: Data?) -> Data {
    let msg = DecodedMessage.response(ResponseMessage(id: id, result: .success(data)))
    var state = State()
    FrameCodec().preencode(&state, msg)
    state.allocate()
    try! FrameCodec().encode(&state, msg)
    return state.buffer
  }

  /// Encode an error response (type == 2, error == true).
  public static func encodeErrorResponse(
    id: UInt, message: String, code: String, errno: Int = 0
  ) -> Data {
    let msg = DecodedMessage.response(
      ResponseMessage(id: id, result: .remoteError(message: message, code: code, errno: errno)))
    var state = State()
    FrameCodec().preencode(&state, msg)
    state.allocate()
    try! FrameCodec().encode(&state, msg)
    return state.buffer
  }

  // MARK: Decode

  /// Decode a complete framed message (4-byte length prefix + body).
  ///
  /// Returns nil for streaming messages (stream != 0) and unknown message types.
  public static func decodeFrame(_ frame: Data) throws -> DecodedMessage? {
    var state = State(frame)
    return try FrameCodec().decode(&state)
  }
}

// MARK: - Errors

/// Errors raised during message decoding.
enum MessagesError: Error {
  /// The message has a non-zero stream field (streaming not supported in v1).
  case streamingNotSupported
  /// The message type byte is not 1 (request) or 2 (response).
  case unknownMessageType
}
