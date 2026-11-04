import Foundation
import Testing

@testable import BareRPC

extension Capture {
  fileprivate var replies: [Data?] {
    sentResponses.compactMap {
      guard case .success(let data) = $0.result else { return nil }
      return data
    }
  }
}

private func isAlreadySent(_ error: Error) -> Bool {
  guard case .alreadySent = error as? RPCError else { return false }
  return true
}

private func isAlreadyReceived(_ error: Error) -> Bool {
  guard case .alreadyReceived = error as? RPCError else { return false }
  return true
}

private func serve(
  _ onRequest: @escaping (IncomingRequest) async throws -> Void
) async throws -> Capture {
  let capture = Capture()
  let handled = Locked(false)
  capture.onRequest = { req in
    defer { handled.value = true }
    try await onRequest(req)
  }
  let server = capture.rpc()
  await server.receive(Messages.encodeRequest(id: 1, command: 1, data: nil))
  #expect(try await waitUntil { handled.value })
  _ = server
  return capture
}

@Suite struct AnswerTests {

  @Test func aRequestCanOnlyBeAnsweredOnce() async throws {
    let errors = Locked<[Bool]>([])
    let sent = Locked<[Bool]>([])

    let capture = try await serve { req in
      sent.append(req.sent)
      try await req.reply(Data([1]))
      sent.append(req.sent)
      for answer in [
        { try await req.reply(Data([2])) },
        { try await req.reject("x") },
        { _ = try await req.createResponseStream() },
      ] as [() async throws -> Void] {
        do { try await answer() } catch { errors.append(isAlreadySent(error)) }
      }
    }

    #expect(sent.value == [false, true])
    #expect(errors.value == [true, true, true])
    #expect(capture.sentResponses.count == 1)
    #expect(capture.replies == [Data([1])])
  }

  @Test func aStreamedAnswerCanNotBeFollowedByAnother() async throws {
    let errors = Locked<[Bool]>([])

    let capture = try await serve { req in
      _ = try await req.createResponseStream()
      do { try await req.reply(nil) } catch { errors.append(isAlreadySent(error)) }
    }

    #expect(errors.value == [true])
    #expect(capture.sentResponses.count == 1)
  }

  @Test func aHandlerThatThrowsAfterReplyingSendsNothingMore() async throws {
    struct Boom: Error {}

    let capture = try await serve { req in
      try await req.reply(Data([1]))
      throw Boom()
    }
    try await Task.sleep(nanoseconds: 50_000_000)

    #expect(capture.sentResponses.count == 1)
    #expect(capture.replies == [Data([1])])
  }

  @Test func theRouterDoesNotReplyForAHandlerThatAnswered() async throws {
    let router = CommandRouter()
    router.on(request: 1) { req in
      try await req.reply(Data([1]))
      return Data([2])
    }

    let capture = try await serve { req in try await router.handle(req) }

    #expect(capture.sentResponses.count == 1)
    #expect(capture.replies == [Data([1])])
  }

  @Test func aRequestBodyCanOnlyBeReadOnce() async throws {
    let errors = Locked<[Bool]>([])

    _ = try await serve { req in
      _ = try await req.createRequestStream()
      do { _ = try await req.createRequestStream() } catch {
        errors.append(isAlreadyReceived(error))
      }
    }

    #expect(errors.value == [true])
  }

  @Test func aRejectionWithoutACodeSendsAnEmptyCode() async throws {
    let pair = RPCPair()
    pair.serverSide.onRequest = { req in try await req.reject("no") }

    do {
      _ = try await pair.client.request(1)
      Issue.record("Expected a rejection")
    } catch let error as RPCRemoteError {
      #expect(error.code == "")
      #expect(error.errno == 0)
    }
  }

  @Test func aStreamedRequestsReplyCanOnlyBeReadOnce() async throws {
    let pair = RPCPair()
    pair.serverSide.onRequest = { req in
      _ = try await req.createRequestStream()
      try await req.reply(Data([1]))
    }

    let (outgoing, response) = try await pair.client.streamRequest(command: 1)
    await outgoing.end()

    #expect(try await response() == Data([1]))
    do {
      _ = try await response()
      Issue.record("Expected alreadyReceived")
    } catch {
      #expect(isAlreadyReceived(error))
    }
  }
}
