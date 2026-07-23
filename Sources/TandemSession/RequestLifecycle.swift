import Foundation
import TandemCore

public enum RequestFailure: Equatable, Sendable {
  /// Acknowledged, but the answer never came. A write may still have taken effect,
  /// so the caller has to establish the real value rather than assume failure.
  case responseTimedOut
  /// Nothing came back at all.
  case noReply
  /// Dropped before it was written, because the queue was full.
  case rejectedByQueue
  /// The session went away underneath it.
  case sessionInvalidated
}

/// Tracks one in-flight request through acknowledgement and answer.
///
/// Every terminal path resolves exactly once. A request can be finished by an answer,
/// a timeout, a disconnect, or a queue eviction, and more than one of those can
/// arrive; resuming a caller twice would trap.
public struct RequestLifecycle: Equatable, Sendable {
  public enum Outcome: Equatable, Sendable {
    case pending
    /// `acknowledged` is false when the answer arrived but the acknowledgement did
    /// not. That is worth recording, but it is not a failure: the device plainly
    /// processed the request.
    case completed(TandemFrame, acknowledged: Bool)
    case failed(RequestFailure)
  }

  // There is deliberately no acknowledgement-timeout event: nothing ever armed one,
  // the response timeout is the single deadline a request needs, and an answer that
  // arrives without its acknowledgement is already recorded on the completion
  // (`completed(_, acknowledged: false)`).
  public enum Event: Equatable, Sendable {
    case acknowledgementReceived
    case responseReceived(TandemFrame)
    case responseTimedOut
    case sessionInvalidated
    case evictedFromQueue
  }

  public let id: OperationID
  public private(set) var isAcknowledged = false
  /// The device repeating an acknowledgement is harmless, but a rising count points
  /// at our own acknowledgements going missing.
  public private(set) var duplicateAcknowledgements = 0
  public private(set) var outcome: Outcome = .pending

  public init(id: OperationID) {
    self.id = id
  }

  public var isResolved: Bool { outcome != .pending }

  /// Returns true when this event resolved the request. Later events are ignored.
  @discardableResult
  public mutating func handle(_ event: Event) -> Bool {
    guard !isResolved else { return false }

    switch event {
    case .acknowledgementReceived:
      if isAcknowledged {
        duplicateAcknowledgements += 1
      } else {
        isAcknowledged = true
      }
      return false

    case .responseReceived(let frame):
      // The answer is proof the device handled the request, so a missing
      // acknowledgement is recorded rather than waited for.
      outcome = .completed(frame, acknowledged: isAcknowledged)
      return true

    case .responseTimedOut:
      outcome = .failed(isAcknowledged ? .responseTimedOut : .noReply)
      return true

    case .sessionInvalidated:
      outcome = .failed(.sessionInvalidated)
      return true

    case .evictedFromQueue:
      outcome = .failed(.rejectedByQueue)
      return true
    }
  }
}
