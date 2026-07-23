import Foundation
import TandemCore
import Testing

@testable import TandemSession

private func answer(_ payload: [UInt8] = [0x01]) throws -> TandemFrame {
  try TandemFrame(dataType: TandemFrame.table1DataType, sequence: 0, payload: Data(payload))
}

private func lifecycle() -> RequestLifecycle {
  RequestLifecycle(id: OperationID(1))
}

@Test func acknowledgementThenAnswerCompletes() throws {
  var request = lifecycle()
  let resolvedByAck = request.handle(.acknowledgementReceived)
  #expect(!resolvedByAck)
  let resolvedByAnswer = request.handle(.responseReceived(try answer()))
  #expect(resolvedByAnswer)

  guard case .completed(_, let acknowledged) = request.outcome else {
    Issue.record("expected completion, got \(request.outcome)")
    return
  }
  #expect(acknowledged)
}

@Test func answerThenAcknowledgementCompletesRegardlessOfOrder() throws {
  var request = lifecycle()
  let resolvedByAnswer = request.handle(.responseReceived(try answer()))
  #expect(resolvedByAnswer)

  // The acknowledgement lands after the answer already resolved the request.
  let resolvedByAck = request.handle(.acknowledgementReceived)
  #expect(!resolvedByAck)
  guard case .completed(_, let acknowledged) = request.outcome else {
    Issue.record("expected completion, got \(request.outcome)")
    return
  }
  #expect(!acknowledged, "the answer arrived first, so it was never acknowledged")
}

@Test func aMissingAcknowledgementDoesNotFailARequestThatWasAnswered() throws {
  // There is no acknowledgement deadline: the answer alone resolves the request,
  // and the absent acknowledgement is recorded on the completion instead.
  var request = lifecycle()
  let resolvedByAnswer = request.handle(.responseReceived(try answer()))
  #expect(resolvedByAnswer)
  guard case .completed(_, let acknowledged) = request.outcome else {
    Issue.record("expected completion, got \(request.outcome)")
    return
  }
  #expect(!acknowledged, "the missing acknowledgement went unrecorded")
}

@Test func anAcknowledgedRequestWithoutAnAnswerReportsTheAmbiguousFailure() {
  var request = lifecycle()
  request.handle(.acknowledgementReceived)
  let resolvedByTimeout = request.handle(.responseTimedOut)
  #expect(resolvedByTimeout)

  // The device took it, so a write may well have landed. The caller has to find
  // out rather than assume nothing happened.
  #expect(request.outcome == .failed(.responseTimedOut))
}

@Test func silenceReportsADifferentFailureFromAnAcknowledgedTimeout() {
  var request = lifecycle()
  let resolvedByTimeout = request.handle(.responseTimedOut)
  #expect(resolvedByTimeout)
  #expect(request.outcome == .failed(.noReply))
}

@Test func duplicateAcknowledgementsAreCountedNotActedOn() {
  var request = lifecycle()
  request.handle(.acknowledgementReceived)
  request.handle(.acknowledgementReceived)
  request.handle(.acknowledgementReceived)

  #expect(request.isAcknowledged)
  #expect(request.duplicateAcknowledgements == 2)
  #expect(!request.isResolved)
}

@Test func aRequestResolvesExactlyOnce() throws {
  // Timeouts, disconnects, and a late answer routinely race. Resuming the caller
  // more than once would trap, so only the first one may win.
  let races: [[RequestLifecycle.Event]] = [
    [.responseTimedOut, .sessionInvalidated, .responseReceived(try answer())],
    [.sessionInvalidated, .responseTimedOut],
    [.responseReceived(try answer()), .responseTimedOut, .evictedFromQueue],
    [.evictedFromQueue, .responseReceived(try answer())],
  ]

  for events in races {
    var request = lifecycle()
    let resolutions = events.reduce(into: 0) { count, event in
      if request.handle(event) { count += 1 }
    }
    #expect(resolutions == 1, "\(events.count) events resolved \(resolutions) times")
  }
}

@Test func theFirstTerminalEventDecidesTheOutcome() throws {
  var request = lifecycle()
  request.handle(.responseTimedOut)
  request.handle(.responseReceived(try answer()))

  #expect(request.outcome == .failed(.noReply), "a late answer overwrote the outcome")
}
