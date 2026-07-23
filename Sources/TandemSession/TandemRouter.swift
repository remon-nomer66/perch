import Foundation
import TandemCore

/// What arrived from the device, once acknowledgement handling is out of the way.
public enum InboundEvent: Equatable, Sendable {
  /// The device acknowledged something we sent.
  case acknowledgement(sequence: UInt8)
  /// A frame carrying data. Whether it answers a request or reports a change is
  /// decided by the controller, which is the only place that knows what is pending.
  case data(TandemFrame)
}

/// Splits inbound frames into acknowledgements and data, and produces the
/// acknowledgements we owe in return.
///
/// Acknowledging is not deferred to the controller: the device expects one promptly,
/// and making it wait behind a queue of application work invites retransmissions.
public struct TandemRouter: Sendable {
  public struct Output: Equatable, Sendable {
    public var events: [InboundEvent]
    /// Frames to write back immediately, ahead of any pending request.
    public var acknowledgements: [TandemFrame]

    public init(events: [InboundEvent] = [], acknowledgements: [TandemFrame] = []) {
      self.events = events
      self.acknowledgements = acknowledgements
    }

    public var isEmpty: Bool { events.isEmpty && acknowledgements.isEmpty }
  }

  public init() {}

  public func route(_ frames: [TandemFrame]) -> Output {
    var output = Output()
    for frame in frames {
      if frame.dataType == TandemFrame.ackDataType {
        // Acknowledging an acknowledgement would bounce between the two endpoints
        // forever.
        output.events.append(.acknowledgement(sequence: frame.sequence))
        continue
      }

      output.events.append(.data(frame))

      guard frame.requiresAcknowledgement else { continue }
      guard let ack = try? TandemFrame.acknowledgement(for: frame.sequence) else {
        // The sequence is out of range, so the frame is not something we can answer.
        // Dropping the acknowledgement is safer than inventing a sequence number.
        continue
      }
      output.acknowledgements.append(ack)
    }
    return output
  }
}
