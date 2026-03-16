// Sources/BareRPC/RPCError.swift
import Foundation

public enum RPCError: Error {
  case missingResponse         // server replied with no data when data was expected
  case streamingNotSupported   // peer sent a streaming message; not supported in v1
}
