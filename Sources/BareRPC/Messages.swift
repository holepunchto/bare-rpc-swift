import CompactEncoding
import Foundation

// MARK: - Decoded message types

enum DecodedMessage {
  case request(RequestMessage)
  case response(ResponseMessage)
}

struct RequestMessage {
  let id: UInt
  let command: UInt
  let data: Data?
}

struct ResponseMessage {
  let id: UInt
  let result: ResponseResult
}

enum ResponseResult {
  case success(Data?)
  case remoteError(message: String, code: String, errno: Int)
}

// MARK: - Codecs

struct RequestMessageCodec: Codec {
  typealias Value = RequestMessage

  func preencode(_ state: inout State, _ value: RequestMessage) {
    Primitive.UInt().preencode(&state, value.id)
    Primitive.UInt().preencode(&state, value.command)
    Primitive.UInt().preencode(&state, 0)
    Primitive.Buffer().preencode(&state, value.data ?? Data())
  }

  func encode(_ state: inout State, _ value: RequestMessage) throws {
    try Primitive.UInt().encode(&state, value.id)
    try Primitive.UInt().encode(&state, value.command)
    try Primitive.UInt().encode(&state, 0 as UInt)
    try Primitive.Buffer().encode(&state, value.data ?? Data())
  }

  func decode(_ state: inout State) throws -> RequestMessage {
    let id = try Primitive.UInt().decode(&state)
    let command = try Primitive.UInt().decode(&state)
    let stream = try Primitive.UInt().decode(&state)
    guard stream == 0 else { throw MessagesError.streamingNotSupported }
    let raw = try Primitive.Buffer().decode(&state)
    return RequestMessage(id: id, command: command, data: raw.isEmpty ? nil : raw)
  }
}

struct ResponseMessageCodec: Codec {
  typealias Value = ResponseMessage

  func preencode(_ state: inout State, _ value: ResponseMessage) {
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

  func encode(_ state: inout State, _ value: ResponseMessage) throws {
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

  func decode(_ state: inout State) throws -> ResponseMessage {
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

struct DecodedMessageCodec: Codec {
  typealias Value = DecodedMessage

  func preencode(_ state: inout State, _ value: DecodedMessage) {
    switch value {
    case .request(let req):
      Primitive.UInt().preencode(&state, 1)
      RequestMessageCodec().preencode(&state, req)
    case .response(let resp):
      Primitive.UInt().preencode(&state, 2)
      ResponseMessageCodec().preencode(&state, resp)
    }
  }

  func encode(_ state: inout State, _ value: DecodedMessage) throws {
    switch value {
    case .request(let req):
      try Primitive.UInt().encode(&state, 1 as UInt)
      try RequestMessageCodec().encode(&state, req)
    case .response(let resp):
      try Primitive.UInt().encode(&state, 2 as UInt)
      try ResponseMessageCodec().encode(&state, resp)
    }
  }

  func decode(_ state: inout State) throws -> DecodedMessage {
    let messageType = try Primitive.UInt().decode(&state)
    switch messageType {
    case 1: return .request(try RequestMessageCodec().decode(&state))
    case 2: return .response(try ResponseMessageCodec().decode(&state))
    default: throw MessagesError.unknownMessageType
    }
  }
}

struct FrameCodec: Codec {
  typealias Value = DecodedMessage?

  func preencode(_ state: inout State, _ value: DecodedMessage?) {
    guard let value else { return }
    Primitive.UInt32().preencode(&state, 0)
    DecodedMessageCodec().preencode(&state, value)
  }

  func encode(_ state: inout State, _ value: DecodedMessage?) throws {
    guard let value else { return }
    var bodyState = State()
    DecodedMessageCodec().preencode(&bodyState, value)
    try Primitive.UInt32().encode(&state, UInt32(bodyState.end))
    try DecodedMessageCodec().encode(&state, value)
  }

  func decode(_ state: inout State) throws -> DecodedMessage? {
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

enum Messages {

  private static func encodeFrame(_ msg: DecodedMessage) -> Data {
    var state = State()
    FrameCodec().preencode(&state, msg)
    state.allocate()
    try! FrameCodec().encode(&state, msg)
    return state.buffer
  }

  static func encodeRequest(id: UInt, command: UInt, data: Data?) -> Data {
    encodeFrame(.request(RequestMessage(id: id, command: command, data: data)))
  }

  static func encodeEvent(command: UInt, data: Data?) -> Data {
    encodeRequest(id: 0, command: command, data: data)
  }

  static func encodeResponse(id: UInt, data: Data?) -> Data {
    encodeFrame(.response(ResponseMessage(id: id, result: .success(data))))
  }

  static func encodeErrorResponse(
    id: UInt, message: String, code: String, errno: Int = 0
  ) -> Data {
    encodeFrame(
      .response(
        ResponseMessage(id: id, result: .remoteError(message: message, code: code, errno: errno))))
  }

  static func decodeFrame(_ frame: Data) throws -> DecodedMessage? {
    var state = State(frame)
    return try FrameCodec().decode(&state)
  }
}

// MARK: - Errors

enum MessagesError: Error {
  case streamingNotSupported
  case unknownMessageType
}
