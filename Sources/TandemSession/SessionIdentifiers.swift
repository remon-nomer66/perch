import Foundation

/// Identifies one attempt to open a channel.
///
/// Opening is asynchronous, so a completion can arrive after the policy has moved on
/// to a different device. Carrying the attempt in the event lets the reducer reject
/// those completions by type rather than by convention.
public struct ConnectionAttempt: Hashable, Sendable {
  public let value: UInt64

  public init(_ value: UInt64) {
    self.value = value
  }

  public var next: ConnectionAttempt { ConnectionAttempt(value &+ 1) }
}

/// Identifies the lifetime of one established session.
///
/// Changes only when a channel is created or destroyed, never when the connection
/// merely advances through verification. Tying it to phase changes instead would
/// invalidate notifications that are still perfectly current.
public struct SessionEpoch: Hashable, Sendable {
  public let value: UInt64

  public init(_ value: UInt64) {
    self.value = value
  }

  public var next: SessionEpoch { SessionEpoch(value &+ 1) }
}

/// Identifies one request. Local only: the device never echoes it, so it serves to
/// discard completions belonging to a request we already finished, not to match a
/// reply to a request.
public struct OperationID: Hashable, Sendable {
  public let value: UInt64

  public init(_ value: UInt64) {
    self.value = value
  }

  public var next: OperationID { OperationID(value &+ 1) }
}
