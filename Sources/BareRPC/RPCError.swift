// Sources/BareRPC/RPCError.swift
import Foundation

public enum RPCError: Error {
  case streamingNotSupported   // peer sent a streaming message; not supported in v1
}
