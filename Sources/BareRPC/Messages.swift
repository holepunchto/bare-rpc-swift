// Sources/BareRPC/Messages.swift
import Foundation
import CompactEncoding

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

// MARK: - Messages

/// Stateless encode/decode for the bare-rpc wire protocol.
///
/// All messages are framed as `[4-byte LE body length][compact-encoded body]`.
/// Uses the compact-encoding two-pass pattern: preencode (calculate size),
/// allocate, encode. The `try!` calls are safe because preencode guarantees
/// the buffer is correctly sized.
///
/// Wire format:
/// - **Request (type 1):** type, id, command, stream, data
/// - **Response (type 2):** type, id, error flag, stream, then data or (message, code, errno)
public enum Messages {

  // MARK: Encode

  /// Encode a request message (type == 1) with the given ID and command.
  ///
  /// - Parameters:
  ///   - id: Request ID. Use 0 for events, positive for tracked requests.
  ///   - command: Application-defined command identifier.
  ///   - data: Optional payload bytes.
  /// - Returns: A complete framed message ready to send.
  public static func encodeRequest(id: UInt, command: UInt, data: Data?) -> Data {
    var state = State()
    preencodeRequestBody(&state, id: id, command: command, data: data)
    state.allocate()
    encodeRequestBody(&state, id: id, command: command, data: data)
    return prependLength(state.buffer)
  }

  /// Encode a fire-and-forget event (request with id == 0).
  ///
  /// - Parameters:
  ///   - command: Application-defined command identifier.
  ///   - data: Optional payload bytes.
  /// - Returns: A complete framed message ready to send.
  public static func encodeEvent(command: UInt, data: Data?) -> Data {
    return encodeRequest(id: 0, command: command, data: data)
  }

  /// Encode a success response (type == 2, error == false).
  ///
  /// - Parameters:
  ///   - id: The request ID being responded to.
  ///   - data: Optional response payload bytes.
  /// - Returns: A complete framed message ready to send.
  public static func encodeResponse(id: UInt, data: Data?) -> Data {
    var state = State()
    Primitive.UInt().preencode(&state, 2)
    Primitive.UInt().preencode(&state, id)
    Primitive.Bool().preencode(&state, false)
    Primitive.UInt().preencode(&state, 0)
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

  /// Encode an error response (type == 2, error == true).
  ///
  /// - Parameters:
  ///   - id: The request ID being responded to.
  ///   - message: Human-readable error message.
  ///   - code: Machine-readable error code string.
  ///   - errno: Numeric error number (default 0).
  /// - Returns: A complete framed message ready to send.
  public static func encodeErrorResponse(id: UInt, message: String, code: String, errno: Int = 0) -> Data {
    var state = State()
    Primitive.UInt().preencode(&state, 2)
    Primitive.UInt().preencode(&state, id)
    Primitive.Bool().preencode(&state, true)
    Primitive.UInt().preencode(&state, 0)
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

  /// Decode a complete framed message (4-byte length prefix + body).
  ///
  /// Returns nil for messages that cannot be handled in v1:
  /// - Streaming messages (stream != 0)
  /// - Unknown message types (not 1 or 2)
  ///
  /// - Parameter frame: A complete frame including the 4-byte LE length prefix.
  /// - Returns: The decoded message, or nil if the message type is unsupported.
  /// - Throws: If the frame data is malformed or truncated.
  public static func decodeFrame(_ frame: Data) throws -> DecodedMessage? {
    var state = State(frame)
    _ = try Primitive.UInt32().decode(&state)
    let type_ = try Primitive.UInt().decode(&state)
    switch type_ {
    case 1: return try decodeRequest(&state).map { .request($0) }
    case 2: return try decodeResponse(&state).map { .response($0) }
    default: return nil
    }
  }

  // MARK: Private helpers

  private static func preencodeRequestBody(_ state: inout State, id: UInt, command: UInt, data: Data?) {
    Primitive.UInt().preencode(&state, 1)
    Primitive.UInt().preencode(&state, id)
    Primitive.UInt().preencode(&state, command)
    Primitive.UInt().preencode(&state, 0)
    preencodeBuffer(&state, data ?? Data())
  }

  private static func encodeRequestBody(_ state: inout State, id: UInt, command: UInt, data: Data?) {
    try! Primitive.UInt().encode(&state, 1)
    try! Primitive.UInt().encode(&state, id)
    try! Primitive.UInt().encode(&state, command)
    try! Primitive.UInt().encode(&state, 0)
    encodeBuffer(&state, data ?? Data())
  }

  /// Preencode a byte buffer as compact-uint length + raw bytes.
  /// Equivalent to `c.buffer.preencode` in the JS compact-encoding library.
  private static func preencodeBuffer(_ state: inout State, _ data: Data) {
    Primitive.UInt().preencode(&state, Swift.UInt(data.count))
    state.end += data.count
  }

  /// Encode a byte buffer as compact-uint length + raw bytes.
  /// Equivalent to `c.buffer.encode` in the JS compact-encoding library.
  private static func encodeBuffer(_ state: inout State, _ data: Data) {
    try! Primitive.UInt().encode(&state, Swift.UInt(data.count))
    if !data.isEmpty {
      state.buffer.replaceSubrange(state.start..<state.start + data.count, with: data)
      state.start += data.count
    }
  }

  /// Decode a compact-uint length-prefixed byte buffer.
  /// Equivalent to `c.buffer.decode` in the JS compact-encoding library.
  private static func decodeBuffer(_ state: inout State) throws -> Data {
    let count = Swift.Int(try Primitive.UInt().decode(&state))
    guard state.remaining >= count else { throw MessagesError.outOfBounds }
    let data = state.buffer.subdata(in: state.start..<state.start + count)
    state.start += count
    return data
  }

  /// Prepend a 4-byte little-endian length prefix to a compact-encoded body.
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

  /// Decode a request body (type == 1). Returns nil for streaming requests.
  private static func decodeRequest(_ state: inout State) throws -> RequestMessage? {
    let id      = try Primitive.UInt().decode(&state)
    let command = try Primitive.UInt().decode(&state)
    let stream  = try Primitive.UInt().decode(&state)
    guard stream == 0 else { return nil }
    let raw = try decodeBuffer(&state)
    return RequestMessage(id: id, command: command, data: raw.isEmpty ? nil : raw)
  }

  /// Decode a response body (type == 2). Returns nil for streaming responses.
  private static func decodeResponse(_ state: inout State) throws -> ResponseMessage? {
    let id     = try Primitive.UInt().decode(&state)
    let isErr  = try Primitive.Bool().decode(&state)
    let stream = try Primitive.UInt().decode(&state)
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

/// Internal errors raised during frame decoding.
enum MessagesError: Error {
  /// The frame data was truncated — not enough bytes to read the expected value.
  case outOfBounds
}
